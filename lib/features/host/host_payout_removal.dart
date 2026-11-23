import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../widgets/common.dart';

/// host/payouts/PayoutAccountRemoval.js – removing a payout account and what can be done with it afterwards.
///
/// Remove takes the account out of UK Stay Hub (it stays open in Stripe, so money already sent still reaches the
/// bank). Delete from Stripe is permanent, and only allowed at a zero balance with nothing in flight.
/// Every rule is decided by the server; these dialogs only show what it says, and the confirm call re-checks.

String _money(num cents, String currency, Strings t) {
  try {
    return NumberFormat.currency(locale: 'en_GB', name: currency.toUpperCase()).format(cents / 100);
  } catch (_) {
    return '${(cents / 100).toStringAsFixed(2)} ${currency.toUpperCase()}';
  }
}

String _day(dynamic v, Strings t) {
  final d = DateTime.tryParse(asString(v));
  return d == null ? '' : DateFormat.yMd('en_GB').format(d.toLocal());
}

String _name(Json a, Strings t) {
  for (final k in ['label', 'payoutIban', 'accountId']) {
    if (asString(a[k]).isNotEmpty) return asString(a[k]);
  }
  return t('PayoutAccountUnnamed', 'Účet bez názvu');
}

/// The server's JSON answer carried by a failed call (blockers, codes), or {}.
Json _errorData(Object e) => e is ApiException && e.data is Map ? asMap(e.data) : <String, dynamic>{};

Widget _blocker(Widget child) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFFFF1F2), borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFFFECDD3))),
      child: DefaultTextStyle(style: AppText.inter(size: 12, color: const Color(0xFF9F1239), height: 1.45), child: child),
    );

Widget _bullets(Iterable<String> items) => Padding(
      padding: const EdgeInsets.only(top: 4, left: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final i in items) Text('• $i')]),
    );

class _Modal extends StatelessWidget {
  const _Modal({required this.title, required this.busy, required this.body, required this.actions});
  final String title;
  final bool busy;
  final List<Widget> body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !busy,
        child: Dialog(
          backgroundColor: Colors.white,
          insetPadding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 512, maxHeight: MediaQuery.sizeOf(context).height * 0.9),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.neutral100))),
                child: Row(children: [
                  Expanded(child: Text(title, style: AppText.inter(size: 16, weight: FontWeight.w600, color: const Color(0xFF1F2937)))),
                  InkWell(onTap: busy ? null : () => Navigator.pop(context), child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.close, size: 16, color: AppColors.neutral400))),
                ]),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: DefaultTextStyle(
                    style: AppText.inter(size: 14, color: const Color(0xFF374151), height: 1.45),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var i = 0; i < body.length; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 12), child: body[i])]),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
                child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
              ),
            ]),
          ),
        ),
      );
}

Widget _cancelButton(Strings t, VoidCallback? onTap) => OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(foregroundColor: AppColors.neutral700, side: const BorderSide(color: AppColors.neutral300), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
      child: Text(t('Cancel', 'Zrušiť'), style: AppText.inter(size: 14, weight: FontWeight.w500)),
    );

Widget _dangerButton(String label, bool busy, VoidCallback? onTap) => FilledButton.icon(
      onPressed: onTap,
      icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.delete_outline, size: 16),
      label: Text(label, style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w500)),
      style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE11D48), disabledBackgroundColor: const Color(0xFFE11D48).withValues(alpha: 0.5), disabledForegroundColor: Colors.white, minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
    );

// ───────────────────────────── Remove ─────────────────────────────
/// "Remove this payout account?" Resolves with the server's new lists on success, else null.
Future<void> showRemoveAccountDialog(BuildContext context, {required String hostId, required Json account, required ValueChanged<Json> onChanged, VoidCallback? onGoToAssignment}) {
  return showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _RemoveDialog(hostId: hostId, account: account, onChanged: onChanged, onGoToAssignment: onGoToAssignment));
}

class _RemoveDialog extends ConsumerStatefulWidget {
  const _RemoveDialog({required this.hostId, required this.account, required this.onChanged, this.onGoToAssignment});
  final String hostId;
  final Json account;
  final ValueChanged<Json> onChanged;
  final VoidCallback? onGoToAssignment;
  @override
  ConsumerState<_RemoveDialog> createState() => _RemoveDialogState();
}

class _RemoveDialogState extends ConsumerState<_RemoveDialog> {
  Json? _check;
  bool _checking = true;
  String? _checkError;
  bool _removing = false;
  String? _makingDefault;

  @override
  void initState() {
    super.initState();
    _runCheck();
  }

  Future<void> _runCheck() async {
    final t = ref.read(stringsProvider);
    setState(() {
      _checking = true;
      _checkError = null;
    });
    try {
      final data = await hostRepo.accountRemovalCheck(widget.hostId, asString(widget.account['accountId']));
      if (mounted) setState(() => _check = data);
    } catch (e) {
      if (mounted) setState(() => _checkError = errorText(e).isEmpty ? t('SomethingWentWrong', 'Niečo sa pokazilo.') : errorText(e));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Json? _has(String code) => asMapList(_check?['blockers']).where((b) => asString(b['code']) == code).firstOrNull;

  Future<void> _makeDefault(Strings t, String accountId) async {
    setState(() => _makingDefault = accountId);
    try {
      final list = await hostRepo.setDefaultStripeAccount(widget.hostId, accountId);
      if (!mounted) return;
      toast(context, t('PayoutDefaultChanged', 'Predvolený účet bol zmenený.'));
      widget.onChanged({'accounts': list});
      await _runCheck();
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _makingDefault = null);
    }
  }

  Future<void> _confirm(Strings t) async {
    setState(() => _removing = true);
    try {
      final data = await hostRepo.removeStripeAccount(widget.hostId, asString(widget.account['accountId']));
      if (!mounted) return;
      toast(context, t('PayoutRemoved', 'Účet bol odstránený.'));
      widget.onChanged(data);
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      final data = _errorData(e);
      String message = errorText(e);
      if (asString(data['code']) == 'changed_meanwhile') {
        message = t('PayoutRemoveChangedMeanwhile', 'Účet sa medzitým zmenil. Skúste to znova.');
      } else if (data['blockers'] is List) {
        // Something new got in the way since the dialog opened.
        setState(() => _check = {...?_check, 'canRemove': false, 'blockers': data['blockers']});
        message = t('PayoutRemoveBlocked', 'Odstránenie momentálne nie je možné');
      }
      toast(context, message, error: true);
      setState(() => _removing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final account = widget.account;
    final blockers = asMapList(_check?['blockers']);
    final busy = _removing || _makingDefault != null;
    final canConfirm = _check?['canRemove'] == true && !_checking && !busy;

    Widget? defaultBlocker;
    if (_has('is_default') != null) {
      defaultBlocker = _blocker(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t('PayoutRemoveBlockDefault', 'Predvolený účet nemožno odstrániť. Najprv nastavte iný účet ako predvolený.')),
        const SizedBox(height: 8),
        for (final other in asMapList(_check?['otherAccounts']))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(child: Text('${_name(other, t)}${other['ready'] == true ? '' : ' (${t('PayoutNotVerified', 'neoverený')})'}')),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: busy ? null : () => _makeDefault(t, asString(other['accountId'])),
                icon: _makingDefault == asString(other['accountId']) ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.star_border, size: 14),
                label: Text(t('PayoutMakeDefault', 'Nastaviť ako predvolený'), style: AppText.inter(size: 12, weight: FontWeight.w500)),
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.neutral700, backgroundColor: Colors.white, side: const BorderSide(color: AppColors.neutral300), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 10), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
              ),
            ]),
          ),
      ]));
    }

    return _Modal(
      title: t('PayoutRemoveTitle', 'Odstrániť výplatný účet?'),
      busy: busy,
      actions: [
        _cancelButton(t, busy ? null : () => Navigator.pop(context)),
        _dangerButton(_removing ? t('PayoutRemoving', 'Odstraňujem…') : t('PayoutRemoveConfirm', 'Odstrániť účet'), _removing, canConfirm ? () => _confirm(t) : null),
      ],
      body: [
        Text.rich(TextSpan(children: [
          TextSpan(text: _name(account, t), style: const TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF1F2937))),
          if (asString(account['payoutIban']).isNotEmpty && asString(account['label']).isNotEmpty) TextSpan(text: ' · ${asString(account['payoutIban'])}', style: const TextStyle(color: AppColors.neutral500)),
        ])),
        Text(t('PayoutRemoveExplainer', ''), style: AppText.inter(size: 12, color: AppColors.neutral500, height: 1.45)),
        if (_checkError != null)
          _blocker(Row(children: [Expanded(child: Text(_checkError!)), TextButton(onPressed: _runCheck, child: Text(t('TryAgain', 'Skúsiť znova'), style: const TextStyle(decoration: TextDecoration.underline)))])),
        if (_checking && _check == null)
          Row(children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 8), Text(t('PayoutRemoveChecking', 'Kontrolujem…'), style: const TextStyle(color: AppColors.neutral500))]),
        if (_check != null && blockers.isNotEmpty)
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t('PayoutRemoveBlocked', 'Odstránenie momentálne nie je možné'), style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFFBE123C))),
            const SizedBox(height: 8),
            if (_has('only_account') != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: _blocker(Text(t('PayoutRemoveBlockOnly', 'Je to váš jediný výplatný účet.')))),
            if (defaultBlocker != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: defaultBlocker),
            if (_has('listings_assigned') != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _blocker(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_has('is_default') != null ? t('PayoutRemoveBlockListingsDefault', '') : t('PayoutRemoveBlockListings', 'Na tento účet sa vyplácajú ponuky:')),
                  _bullets([for (final l in asMapList(_has('listings_assigned')!['listings'])) asString(l['name'], asString(l['_id']))]),
                  if (widget.onGoToAssignment != null)
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onGoToAssignment!();
                      },
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 44), alignment: Alignment.centerLeft),
                      child: Text(t('PayoutGoToAssignment', 'Prejsť na priradenie ponúk'), style: AppText.inter(size: 12, weight: FontWeight.w500, color: const Color(0xFF9F1239)).copyWith(decoration: TextDecoration.underline)),
                    ),
                ])),
              ),
            if (_has('pending_payouts') != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _blocker(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t('PayoutRemoveBlockPayouts', 'Čakajú nevyplatené rezervácie:')),
                  _bullets([for (final r in asMapList(_has('pending_payouts')!['reservations'])) '${_money(asDouble(r['amountCents']), asString(r['currency'], 'gbp'), t)}${asString(r['checkInDate']).isEmpty ? '' : ' · ${t('PayoutCheckIn', 'príchod')} ${_day(r['checkInDate'], t)}'}']),
                ])),
              ),
            if (_has('pending_reservations') != null)
              _blocker(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t('PayoutRemoveBlockReservations', 'Prebiehajú rezervácie:')),
                _bullets([for (final r in asMapList(_has('pending_reservations')!['reservations'])) asString(r['checkInDate']).isEmpty ? asString(r['_id']) : '${t('PayoutCheckIn', 'príchod')} ${_day(r['checkInDate'], t)}']),
              ])),
          ]),
        if (_check != null && _checking)
          Row(children: [const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 8), Text(t('PayoutRemoveChecking', 'Kontrolujem…'), style: AppText.inter(size: 12, color: AppColors.neutral500))]),
      ],
    );
  }
}

// ───────────────────────────── Delete in Stripe ─────────────────────────────
class _DeleteInStripeDialog extends ConsumerStatefulWidget {
  const _DeleteInStripeDialog({required this.hostId, required this.account, required this.onDeleted});
  final String hostId;
  final Json account;
  final ValueChanged<Json> onDeleted;
  @override
  ConsumerState<_DeleteInStripeDialog> createState() => _DeleteState();
}

class _DeleteState extends ConsumerState<_DeleteInStripeDialog> {
  Json? _check;
  String? _checkError;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _runCheck();
  }

  Future<void> _runCheck() async {
    setState(() {
      _check = null;
      _checkError = null;
    });
    try {
      final data = await hostRepo.stripeDeletionCheck(widget.hostId, asString(widget.account['accountId']));
      if (mounted) setState(() => _check = data);
    } catch (e) {
      if (mounted) setState(() => _checkError = errorText(e));
    }
  }

  Future<void> _confirm(Strings t) async {
    setState(() => _deleting = true);
    try {
      final data = await hostRepo.deleteAccountInStripe(widget.hostId, asString(widget.account['accountId']));
      if (!mounted) return;
      toast(context, t('PayoutDeleted', 'Účet bol natrvalo odstránený zo Stripe.'));
      widget.onDeleted(data);
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      final data = _errorData(e);
      if (data['blockers'] is List) setState(() => _check = {'canDelete': false, 'blockers': data['blockers']});
      toast(context, errorText(e).isEmpty ? t('PayoutDeleteBlocked', 'Zmazanie nie je možné') : errorText(e), error: true);
      setState(() => _deleting = false);
    }
  }

  String _describe(Json b, Strings t) {
    switch (asString(b['code'])) {
      case 'balance_not_zero':
        return '${t('PayoutDeleteBlockBalance', 'Zostatok nie je nulový')}: ${asMapList(b['amounts']).map((a) => _money(asDouble(a['amountCents']), asString(a['currency'], 'gbp'), t)).join(', ')}';
      case 'payouts_in_flight':
        return '${t('PayoutDeleteBlockInFlight', 'Prebiehajú výplaty')}: ${asMapList(b['payouts']).map((p) => '${_money(asDouble(p['amountCents']), asString(p['currency'], 'gbp'), t)}${asString(p['arrivalDate']).isEmpty ? '' : ' (${_day(p['arrivalDate'], t)})'}').join(', ')}';
      case 'recent_transfers':
        return '${t('PayoutDeleteBlockRecent', 'Nedávne prevody. Zmazať môžete od')} ${_day(b['deletableFrom'], t)}.';
      case 'not_removed_yet':
        return t('PayoutDeleteBlockNotRemoved', 'Účet najprv odstráňte z Putka.');
      case 'already_deleted':
        return t('PayoutDeleteBlockAlreadyDeleted', 'Účet je už zmazaný.');
      default:
        return t('PayoutDeleteBlockStripeError', 'Stripe teraz neodpovedal.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    return _Modal(
      title: t('PayoutDeleteTitle', 'Natrvalo zmazať účet zo Stripe?'),
      busy: _deleting,
      actions: [
        _cancelButton(t, _deleting ? null : () => Navigator.pop(context)),
        _dangerButton(_deleting ? t('PayoutDeleting', 'Mažem…') : t('PayoutDeleteConfirm', 'Zmazať zo Stripe'), _deleting, _check?['canDelete'] == true && !_deleting ? () => _confirm(t) : null),
      ],
      body: [
        Text(_name(widget.account, t), style: const TextStyle(fontWeight: FontWeight.w500, color: Color(0xFF1F2937))),
        Text(t('PayoutDeleteExplainer', ''), style: AppText.inter(size: 12, color: AppColors.neutral500, height: 1.45)),
        if (_check == null && _checkError == null)
          Row(children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 8), Text(t('PayoutDeleteChecking', 'Kontrolujem…'), style: const TextStyle(color: AppColors.neutral500))]),
        if (_checkError != null) _blocker(Row(children: [Expanded(child: Text(_checkError!)), TextButton(onPressed: _runCheck, child: Text(t('TryAgain', 'Skúsiť znova'), style: const TextStyle(decoration: TextDecoration.underline)))])),
        if (_check != null && _check!['canDelete'] != true)
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t('PayoutDeleteBlocked', 'Zmazanie momentálne nie je možné'), style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFFBE123C))),
            const SizedBox(height: 8),
            for (final b in asMapList(_check!['blockers'])) Padding(padding: const EdgeInsets.only(bottom: 8), child: _blocker(Text(_describe(b, t)))),
          ]),
      ],
    );
  }
}

// ───────────────────────────── Removed accounts ─────────────────────────────
/// The host's removed accounts: when each was removed, and the two things that can still be done with it.
class RemovedAccountsList extends ConsumerStatefulWidget {
  const RemovedAccountsList({super.key, required this.hostId, required this.removed, required this.onChanged});
  final String hostId;
  final List<Json> removed;
  final ValueChanged<Json> onChanged;
  @override
  ConsumerState<RemovedAccountsList> createState() => _RemovedState();
}

class _RemovedState extends ConsumerState<RemovedAccountsList> {
  String? _busy;

  Future<void> _restore(Strings t, Json account) async {
    final id = asString(account['accountId']);
    setState(() => _busy = id);
    try {
      final data = await hostRepo.restoreStripeAccount(widget.hostId, id);
      if (!mounted) return;
      toast(context, t('PayoutRestored', 'Účet bol znova pripojený.'));
      widget.onChanged(data);
    } catch (e) {
      if (!mounted) return;
      final code = _errorData(e)['code'];
      toast(context, code == 'deleted_in_stripe' || code == 'unreachable_in_stripe' ? t('PayoutRestoreGone', 'Tento účet už v službe Stripe neexistuje, nemožno ho obnoviť.') : errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    if (widget.removed.isEmpty) return const SizedBox.shrink();
    Widget btn(String label, IconData icon, VoidCallback? onTap, {Color? fg, Color? border, bool spin = false}) => OutlinedButton.icon(
          onPressed: onTap,
          icon: spin ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon, size: 14),
          label: Text(label, style: AppText.inter(size: 12, weight: FontWeight.w500)),
          style: OutlinedButton.styleFrom(foregroundColor: fg ?? AppColors.neutral700, backgroundColor: Colors.white, side: BorderSide(color: border ?? AppColors.neutral300), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
        );
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.only(top: 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t('PayoutRemovedAccounts', 'Odstránené účty'), style: AppText.inter(size: 14, weight: FontWeight.w600, color: const Color(0xFF1F2937))),
        const SizedBox(height: 4),
        Text(t('PayoutRemovedAccountsExplainer', ''), style: AppText.inter(size: 12, color: AppColors.neutral500, height: 1.45)),
        const SizedBox(height: 12),
        for (final a in widget.removed)
          Builder(builder: (_) {
            final id = asString(a['accountId']);
            final gone = asString(a['stripeDeletedAt']).isNotEmpty;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(6)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(_name(a, t), style: AppText.inter(size: 14, color: const Color(0xFF374151))),
                Text('$id${asString(a['disconnectedAt']).isEmpty ? '' : ' · ${t('PayoutRemovedOn', 'odstránený')} ${_day(a['disconnectedAt'], t)}'}${gone ? ' · ${t('PayoutDeletedInStripe', 'zmazaný v Stripe')} ${_day(a['stripeDeletedAt'], t)}' : ''}', style: AppText.inter(size: 12, color: AppColors.neutral400)),
                if (!gone) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    btn(t('PayoutRestore', 'Obnoviť'), Icons.restart_alt, _busy == id ? null : () => _restore(t, a), spin: _busy == id),
                    btn(t('PayoutDeleteInStripe', 'Zmazať zo Stripe'), Icons.delete_outline, _busy == id ? null : () => showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _DeleteInStripeDialog(hostId: widget.hostId, account: a, onDeleted: widget.onChanged)), fg: const Color(0xFFBE123C), border: const Color(0xFFFECDD3)),
                  ]),
                ],
              ]),
            );
          }),
      ]),
    );
  }
}
