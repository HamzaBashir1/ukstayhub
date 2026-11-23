import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../state/auth.dart';
import '../../widgets/common.dart';
import 'editor_fields.dart';

/// host/account/HostAccountPage.js – personal details, email, password and billing.

const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;

String _digits(String v) => v.replaceAll(RegExp(r'\D'), '');

String _accountError(Object e, Strings t) {
  if (e is ApiException && e.status == 401) return t.pick('Platnosť relácie vypršala. Prihláste sa znova.', 'Your session has expired. Please log in again.');
  return errorText(e);
}

/// A labelled input in the account page style (small caps label, rounded-xl field).
class _Labelled extends StatefulWidget {
  const _Labelled({required this.label, required this.value, this.onChanged, this.enabled = true, this.placeholder, this.keyboard, this.error, this.password = false, this.caps = true, this.icon, this.maxLength, this.autofill, this.upper = false});
  final String label;
  final String value;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final String? placeholder;
  final TextInputType? keyboard;
  final String? error;
  final bool password;
  final bool caps;
  final IconData? icon;
  final int? maxLength;
  final Iterable<String>? autofill;
  final bool upper;
  @override
  State<_Labelled> createState() => _LabelledState();
}

class _LabelledState extends State<_Labelled> {
  late final _c = TextEditingController(text: widget.value);
  final _focus = FocusNode();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(_Labelled old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _c.text != widget.value) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          Flexible(child: Text(widget.caps ? widget.label.toUpperCase() : widget.label, style: AppText.inter(size: widget.caps ? 12 : 14, weight: FontWeight.w700, color: widget.caps ? AppColors.neutral500 : AppColors.neutral700, letterSpacing: widget.caps ? 0.3 : 0))),
          if (widget.icon != null) ...[const SizedBox(width: 8), Icon(widget.icon, size: 12, color: _forest)],
        ]),
      ),
      Container(
        decoration: BoxDecoration(
          color: widget.enabled ? Colors.white : AppColors.neutral50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: widget.error != null ? const Color(0xFFF87171) : (focused ? _forest : AppColors.neutral200)),
          boxShadow: focused ? [BoxShadow(color: _forest.withValues(alpha: 0.15), spreadRadius: 2)] : null,
        ),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _c,
              focusNode: _focus,
              enabled: widget.enabled,
              obscureText: widget.password && _obscure,
              keyboardType: widget.keyboard,
              maxLength: widget.maxLength,
              textCapitalization: widget.upper ? TextCapitalization.characters : TextCapitalization.none,
              autofillHints: widget.autofill,
              onChanged: widget.onChanged,
              style: AppText.inter(size: 15, color: widget.enabled ? _forest : AppColors.neutral500),
              decoration: InputDecoration(
                counterText: '',
                hintText: widget.placeholder,
                hintStyle: AppText.inter(size: 15, color: AppColors.neutral400),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.fromLTRB(16, 14, widget.password ? 0 : 16, 14),
              ),
            ),
          ),
          if (widget.password)
            InkWell(
              onTap: () => setState(() => _obscure = !_obscure),
              child: SizedBox(width: 48, height: 48, child: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18, color: AppColors.neutral400)),
            ),
        ]),
      ),
      EditorFieldError(widget.error),
    ]);
  }
}

/// The billing form in a bottom sheet, for screens that need it outside the Account page
/// (the Stripe onboarding return). `onSaved` receives the saved account.
Future<void> showHostBillingSheet(BuildContext context, {Json? billing, required ValueChanged<Json> onSaved}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: _BillingForm(
            billing: billing,
            onSaved: (a) {
              Navigator.pop(ctx);
              onSaved(a);
            },
          ),
        ),
      ),
    ),
  );
}

class HostAccountScreen extends ConsumerStatefulWidget {
  const HostAccountScreen({super.key});
  @override
  ConsumerState<HostAccountScreen> createState() => _HostAccountScreenState();
}

class _HostAccountScreenState extends ConsumerState<HostAccountScreen> {
  String _status = 'loading';
  Object? _loadError;
  Json _account = {};
  Map<String, String> _form = {'name': '', 'lastName': '', 'phoneNumber': '', 'gender': 'other', 'address': '', 'aboutYou': ''};
  bool _editing = false;
  bool _saving = false;
  bool _showSecurity = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, String> _toForm(Json a) => {
        'name': asString(a['name']),
        'lastName': asString(a['lastName']),
        'phoneNumber': asString(a['phoneNumber']),
        'gender': asString(a['gender'], 'other'),
        'address': asString(a['address']),
        'aboutYou': asString(a['aboutYou']),
      };

  Future<void> _load() async {
    setState(() => _status = 'loading');
    try {
      final a = await hostRepo.account();
      if (!mounted) return;
      setState(() {
        _account = a;
        _form = _toForm(a);
        _status = 'ready';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = e;
          _status = 'error';
        });
      }
    }
  }

  Future<void> _save() async {
    final t = ref.read(stringsProvider);
    final phone = (_form['phoneNumber'] ?? '').replaceAll(RegExp(r'\s'), '');
    if ((_form['name'] ?? '').trim().isEmpty || (_form['lastName'] ?? '').trim().isEmpty) {
      toast(context, t.pick('Zadajte meno a priezvisko.', 'Enter your first and last name.'), error: true);
      return;
    }
    if (phone.isNotEmpty && !RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(phone)) {
      toast(context, t.pick('Zadajte platné telefónne číslo v medzinárodnom formáte.', 'Enter a valid international phone number.'), error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final payload = <String, dynamic>{..._form, 'name': _form['name']!.trim(), 'lastName': _form['lastName']!.trim(), 'lang': t.lang};
      // Left out entirely when blank: the server rejects an empty string as an invalid phone number.
      if (phone.isNotEmpty) {
        payload['phoneNumber'] = phone;
      } else {
        payload.remove('phoneNumber');
      }
      final saved = await hostRepo.updateAccount(payload);
      if (!mounted) return;
      setState(() {
        _account = saved;
        _form = _toForm(saved);
        _editing = false;
      });
      toast(context, t.pick('Údaje boli aktualizované.', 'Details updated.'));
    } catch (e) {
      if (mounted) toast(context, _accountError(e, t), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _card({required Widget child}) => Container(
        padding: EdgeInsets.all(MediaQuery.sizeOf(context).width >= 768 ? 28 : 20),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200)),
        child: child,
      );

  Widget _outlineBtn(String label, IconData icon, VoidCallback? onTap, {bool full = false}) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200, width: 2)),
          child: Row(mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 16, color: _forest),
            const SizedBox(width: 8),
            Flexible(child: Text(label, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest))),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final width = MediaQuery.sizeOf(context).width;
    final md = width >= 768;
    Widget page(Widget child) => ListView(padding: const EdgeInsets.only(bottom: 32), children: [Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 768), child: Padding(padding: EdgeInsets.symmetric(horizontal: md ? 0 : 16), child: child)))]);

    if (_status == 'loading') {
      Widget box(double h) => Container(height: h, decoration: BoxDecoration(color: AppColors.neutral100, borderRadius: BorderRadius.circular(24)));
      return page(Column(children: [Container(height: 32, width: 192, decoration: BoxDecoration(color: AppColors.neutral200, borderRadius: BorderRadius.circular(8))), const SizedBox(height: 16), box(144), const SizedBox(height: 16), box(256)]));
    }
    if (_status == 'error') {
      return page(Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFFECACA))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.pick('Nepodarilo sa načítať váš účet', "We couldn't load your account"), style: AppText.inter(size: 18, weight: FontWeight.w700, color: const Color(0xFFB91C1C))),
          const SizedBox(height: 4),
          Text(_accountError(_loadError!, t), style: AppText.inter(size: 15, color: const Color(0xCC7F1D1D))),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh, size: 16), label: Text(t.pick('Skúsiť znova', 'Try again'), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700)), style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 20), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
        ]),
      ));
    }

    Widget field(String key, String label, {String? placeholder, TextInputType? keyboard}) => _Labelled(label: label, value: _form[key] ?? '', enabled: _editing, placeholder: placeholder, keyboard: keyboard, onChanged: (v) => _form[key] = v);

    final genderField = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(t.pick('POHLAVIE', 'GENDER'), style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3))),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(color: _editing ? Colors.white : AppColors.neutral50, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: const ['female', 'male', 'other'].contains(_form['gender']) ? _form['gender'] : 'other',
            isExpanded: true,
            style: AppText.inter(size: 15, color: _editing ? _forest : AppColors.neutral500),
            items: [DropdownMenuItem(value: 'female', child: Text(t.pick('Žena', 'Female'))), DropdownMenuItem(value: 'male', child: Text(t.pick('Muž', 'Male'))), DropdownMenuItem(value: 'other', child: Text(t.pick('Iné', 'Other')))],
            onChanged: _editing ? (v) => setState(() => _form['gender'] = v ?? 'other') : null,
          ),
        ),
      ),
    ]);

    final cells = <Widget>[
      field('name', t.pick('Meno', 'First name')),
      field('lastName', t.pick('Priezvisko', 'Last name')),
      _Labelled(label: t.pick('E-mail', 'Email'), value: asString(_account['email']), enabled: false, icon: Icons.shield_outlined),
      _EmailChange(account: _account, onChanged: (saved) {
        setState(() => _account = saved);
        // The email is the login: sign in again with the new one.
        final router = GoRouter.of(context);
        final auth = ref.read(authProvider.notifier);
        Timer(const Duration(milliseconds: 1500), () async {
          await auth.logout();
          router.go('/login');
        });
      }),
      field('phoneNumber', t.pick('Telefón', 'Phone'), placeholder: '+44 7700 900000', keyboard: TextInputType.phone),
      genderField,
      field('address', t.pick('Adresa', 'Address')),
    ];

    Widget grid2(List<Widget> items) {
      if (!md) return Column(children: [for (var i = 0; i < items.length; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 20), child: SizedBox(width: double.infinity, child: items[i]))]);
      final rows = <Widget>[];
      for (var i = 0; i < items.length; i += 2) {
        rows.add(Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 20),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: items[i]), const SizedBox(width: 20), Expanded(child: i + 1 < items.length ? items[i + 1] : const SizedBox())]),
        ));
      }
      return Column(children: rows);
    }

    return page(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t.pick('Osobné údaje', 'Personal details'), style: AppText.inter(size: md ? 30 : 24, weight: FontWeight.w700, color: _forest, height: 1.25)),
      const SizedBox(height: 4),
      Text(t.pick('Vaša identita a kontakt. Nezobrazuje sa v ponukách.', 'Your identity and how we reach you. Not shown on your listings.'), style: AppText.inter(size: 15, color: AppColors.neutral500)),
      const SizedBox(height: 24),
      _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.only(bottom: 20),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.neutral100))),
            child: Row(children: [
              Expanded(child: Text(t.pick('Údaje', 'Details'), style: AppText.inter(size: 18, weight: FontWeight.w700, color: _forest))),
              _outlineBtn(_editing ? t.pick('Zrušiť', 'Cancel') : t.pick('Upraviť', 'Edit'), Icons.edit_outlined, () => setState(() {
                    if (_editing) _form = _toForm(_account);
                    _editing = !_editing;
                  })),
            ]),
          ),
          const SizedBox(height: 24),
          grid2(cells),
          if (_editing) ...[
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const SizedBox.shrink(),
                label: Text(_saving ? t.pick('Ukladám…', 'Saving…') : t.pick('Uložiť zmeny', 'Save changes'), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700)),
                style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: Size(md ? 0 : double.infinity, 44), padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.only(top: 24),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Align(alignment: md ? Alignment.centerLeft : Alignment.center, child: _outlineBtn(t.pick('Heslo a bezpečnosť', 'Password and security'), Icons.key_outlined, () => setState(() => _showSecurity = !_showSecurity), full: !md)),
              if (_showSecurity) _PasswordForm(email: asString(_account['email'])),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 24),
      _BillingSection(account: _account, onSaved: (a) => setState(() => _account = a)),
    ]));
  }
}

// ───────────────────────────── Email change ─────────────────────────────
class _EmailChange extends ConsumerStatefulWidget {
  const _EmailChange({required this.account, required this.onChanged});
  final Json account;
  final ValueChanged<Json> onChanged;
  @override
  ConsumerState<_EmailChange> createState() => _EmailChangeState();
}

class _EmailChangeState extends ConsumerState<_EmailChange> {
  bool _open = false;
  bool _busy = false;
  String _email = '';
  String _password = '';

  Future<void> _submit() async {
    final t = ref.read(stringsProvider);
    if (_busy) return;
    if (_email.trim().isEmpty || _password.isEmpty) {
      toast(context, t.pick('Zadajte nový e-mail a svoje aktuálne heslo.', 'Enter the new email and your current password.'), error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await hostRepo.changeEmail(_email.trim(), _password);
      final saved = asMap(result['account'] is Map ? result['account'] : result);
      if (!mounted) return;
      setState(() {
        _open = false;
        _email = '';
        _password = '';
      });
      widget.onChanged(saved);
      toast(context, t.pick('E-mail bol zmenený. Prihláste sa znova s novým e-mailom.', 'Email changed. Please log in again with your new email.'));
    } catch (e) {
      if (mounted) toast(context, _accountError(e, t), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    if (!_open) {
      return Align(
        alignment: Alignment.bottomLeft,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _open = true),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral200, width: 2)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.edit_outlined, size: 16, color: _forest), const SizedBox(width: 8), Text(t.pick('Zmeniť e-mail', 'Change email'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest))]),
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.pick('Vaše ponuky a rezervácie zostanú bezo zmeny. Všetky e-maily budeme posielať na novú adresu. Aktuálny e-mail: ${asString(widget.account['email'])}', 'Your listings and bookings stay as they are. All emails will go to the new address. Current email: ${asString(widget.account['email'])}'), style: AppText.inter(size: 13, color: AppColors.neutral500, height: 1.5)),
        const SizedBox(height: 16),
        _Labelled(label: t.pick('Nový e-mail', 'New email'), caps: false, value: _email, keyboard: TextInputType.emailAddress, autofill: const [AutofillHints.email], onChanged: (v) => _email = v),
        const SizedBox(height: 6),
        Text(t.pick('Nový e-mail nesmie mať už vytvorený účet na UK Stay Hub (hostiteľ ani cestovateľ). Už používané adresy sa odmietnu.', 'The new email must not already have a UK Stay Hub account (host or traveller). Addresses already in use are rejected.'), style: AppText.inter(size: 12, weight: FontWeight.w600, color: const Color(0xFFB45309), height: 1.4)),
        const SizedBox(height: 16),
        _Labelled(label: t.pick('Aktuálne heslo', 'Current password'), caps: false, value: _password, password: true, autofill: const [AutofillHints.password], onChanged: (v) => _password = v),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          OutlinedButton(onPressed: _busy ? null : () => setState(() => _open = false), style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: AppColors.neutral200, width: 2), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: Text(t.pick('Zrušiť', 'Cancel'), style: AppText.inter(size: 14, weight: FontWeight.w700))),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _submit,
            icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const SizedBox.shrink(),
            label: Text(_busy ? t.pick('Ukladám…', 'Saving…') : t.pick('Aktualizovať e-mail', 'Update email'), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700)),
            style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ]),
      ]),
    );
  }
}

// ───────────────────────────── Password ─────────────────────────────
class _PasswordForm extends ConsumerStatefulWidget {
  const _PasswordForm({required this.email});
  final String email;
  @override
  ConsumerState<_PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends ConsumerState<_PasswordForm> {
  String _current = '';
  String _next = '';
  String _confirm = '';
  bool _saving = false;
  int _reset = 0;

  Future<void> _submit() async {
    final t = ref.read(stringsProvider);
    if (_next.length < 8) {
      toast(context, t.pick('Nové heslo musí mať aspoň 8 znakov.', 'New password must have at least 8 characters.'), error: true);
      return;
    }
    if (_next != _confirm) {
      toast(context, t.pick('Nové heslá sa nezhodujú.', 'New passwords do not match.'), error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await hostRepo.changePassword(_current, _next);
      if (!mounted) return;
      // The session is not ended: a host may be mid-edit on a listing.
      setState(() {
        _current = '';
        _next = '';
        _confirm = '';
        _reset++;
      });
      toast(context, t.pick('Heslo bolo zmenené.', 'Password changed.'));
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final md = MediaQuery.sizeOf(context).width >= 768;
    return Container(
      key: ValueKey(_reset),
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Labelled(label: t.pick('Aktuálne heslo', 'Current password'), caps: false, value: _current, password: true, autofill: const [AutofillHints.password], onChanged: (v) => _current = v),
        const SizedBox(height: 16),
        _Labelled(label: t.pick('Nové heslo', 'New password'), caps: false, value: _next, password: true, autofill: const [AutofillHints.newPassword], onChanged: (v) => _next = v),
        const SizedBox(height: 16),
        _Labelled(label: t.pick('Potvrďte nové heslo', 'Confirm new password'), caps: false, value: _confirm, password: true, autofill: const [AutofillHints.newPassword], onChanged: (v) => _confirm = v),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _saving ? null : _submit,
            icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const SizedBox.shrink(),
            label: Text(_saving ? t.pick('Ukladám…', 'Saving…') : t.pick('Zmeniť heslo', 'Change password'), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700)),
            style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: Size(md ? 0 : double.infinity, 44), padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ),
      ]),
    );
  }
}

// ───────────────────────────── Billing ─────────────────────────────
class _BillingSection extends ConsumerStatefulWidget {
  const _BillingSection({required this.account, required this.onSaved});
  final Json account;
  final ValueChanged<Json> onSaved;
  @override
  ConsumerState<_BillingSection> createState() => _BillingSectionState();
}

class _BillingSectionState extends ConsumerState<_BillingSection> {
  bool _open = false;

  bool _complete(Json? b) {
    if (b == null || b.isEmpty) return false;
    bool blank(dynamic v) => asString(v).trim().isEmpty;
    if (blank(b['companyName'])) return false;
    if (asString(b['subjectType']) != 'individual' && (blank(b['ico']) || blank(b['dic']))) return false;
    return !blank(b['streetNumber']) && !blank(b['city']) && !blank(b['zipcode']) && !blank(b['countryCode']);
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final billing = widget.account['billing'] is Map ? asMap(widget.account['billing']) : null;
    final complete = _complete(billing);
    final md = MediaQuery.sizeOf(context).width >= 768;
    return Container(
      padding: EdgeInsets.all(md ? 28 : 20),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Row(children: [
            Container(width: 40, height: 40, decoration: BoxDecoration(color: _gold.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: _gold.withValues(alpha: 0.2))), child: const Icon(Icons.business_outlined, size: 18, color: _forest)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.pick('Fakturačné údaje', 'Billing details'), style: AppText.inter(size: 18, weight: FontWeight.w700, color: _forest)),
                Text(t.pick('Slúžia na faktúru za poplatok platformy, ktorú vám UK Stay Hub vystavuje. Nezobrazujú sa hosťom.', 'Used for the invoice UK Stay Hub issues you for the platform fee. Not shown to guests.'), style: AppText.inter(size: 13, color: AppColors.neutral500, height: 1.4)),
              ]),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: complete ? const Color(0xFFF0FDF4) : const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(99), border: Border.all(color: complete ? const Color(0xFFBBF7D0) : const Color(0xFFFDE68A))),
              child: Text(complete ? t.pick('Kompletné', 'Complete') : t.pick('Neúplné', 'Incomplete'), style: AppText.inter(size: 12, weight: FontWeight.w700, color: complete ? const Color(0xFF15803D) : const Color(0xFFB45309))),
            ),
          ]),
        ),
        if (_open) _BillingForm(billing: billing, onSaved: widget.onSaved),
      ]),
    );
  }
}

class _BillingForm extends ConsumerStatefulWidget {
  const _BillingForm({required this.billing, required this.onSaved});
  final Json? billing;
  final ValueChanged<Json> onSaved;
  @override
  ConsumerState<_BillingForm> createState() => _BillingFormState();
}

class _BillingFormState extends ConsumerState<_BillingForm> {
  late Map<String, String> _f = _toForm(widget.billing);
  Map<String, String> _errors = {};
  bool _saving = false;
  String _lookupStatus = 'idle';
  String _lookupMessage = '';
  Timer? _debounce;
  int _formKey = 0;

  static Map<String, String> _toForm(Json? b) => {
        'subjectType': asString(b?['subjectType'], 'business'),
        'companyName': asString(b?['companyName']),
        'ico': asString(b?['ico']),
        'dic': asString(b?['dic']),
        'icDph': asString(b?['icDph']),
        'streetNumber': asString(b?['streetNumber']),
        'city': asString(b?['city']),
        'zipcode': asString(b?['zipcode']),
        'countryCode': asString(b?['countryCode'], 'GB'),
      };

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  bool get _business => _f['subjectType'] == 'business';
  bool get _uk => const ['GB', 'UK'].contains((_f['countryCode'] ?? '').trim().toUpperCase());

  /// UK Companies House numbers: 8 characters, digits or a 2-letter prefix + 6 digits (e.g. 01234567, SC123456).
  static final _companyNo = RegExp(r'^([0-9]{8}|[A-Z]{2}[0-9]{6})\$');
  String _companyNumber(String v) => v.replaceAll(RegExp(r'\s'), '').toUpperCase();

  void _set(String key, String v) {
    _f[key] = v;
    if (_errors.containsKey(key)) setState(() => _errors.remove(key));
    if (key == 'ico') _scheduleLookup();
  }

  void _scheduleLookup() {
    _debounce?.cancel();
    final t = ref.read(stringsProvider);
    final ico = _companyNumber(_f['ico'] ?? '');
    if (!_business || !_companyNo.hasMatch(ico)) {
      if (_lookupStatus != 'idle') setState(() => _lookupStatus = 'idle');
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      setState(() {
        _lookupStatus = 'loading';
        _lookupMessage = t.pick('Vyhľadávam v obchodnom registri…', 'Looking up the business register…');
      });
      try {
        final d = await hostRepo.icoLookup(ico);
        if (!mounted) return;
        if (d['found'] != true) throw ApiException('NOT_FOUND');
        setState(() {
          _f['companyName'] = asString(d['name'], _f['companyName'] ?? '');
          _f['ico'] = asString(d['ico'], ico);
          _f['dic'] = asString(d['dic']);
          _f['icDph'] = asString(d['icDph']);
          _f['streetNumber'] = asString(d['street'], _f['streetNumber'] ?? '');
          _f['city'] = asString(d['city'], _f['city'] ?? '');
          _f['zipcode'] = asString(d['zip'], _f['zipcode'] ?? '');
          _f['countryCode'] = asString(d['countryCode'], 'GB');
          _formKey++;
          _lookupStatus = 'success';
          _lookupMessage = t.pick('Vyplnené z obchodného registra.', 'Filled from the business register.');
        });
      } catch (_) {
        if (mounted) {
          setState(() {
            _lookupStatus = 'manual';
            _lookupMessage = t.pick('Vyhľadanie v obchodnom registri nie je dostupné. Zadajte údaje manuálne.', 'Business-register lookup is unavailable. Enter the details manually.');
          });
        }
      }
    });
  }

  bool _validate(Strings t) {
    final e = <String, String>{};
    final business = _business;
    if ((_f['companyName'] ?? '').trim().isEmpty) {
      e['companyName'] = business ? t.pick('Názov spoločnosti je povinný', 'Company name is required') : t.pick('Celé právne meno je povinné', 'Full legal name is required');
    }
    if (business) {
      final ico = _f['ico'] ?? '';
      if (ico.trim().isEmpty) {
        e['ico'] = 'Company number is required';
      } else if (_uk && !_companyNo.hasMatch(_companyNumber(ico))) {
        e['ico'] = 'A UK company number has 8 characters, e.g. 01234567 or SC123456';
      }
      final dic = _f['dic'] ?? '';
      if (dic.trim().isEmpty) {
        e['dic'] = 'Unique Taxpayer Reference (UTR) is required';
      } else if (_uk && _digits(dic).length != 10) {
        e['dic'] = 'A UTR is 10 digits';
      }
    }
    final icDph = (_f['icDph'] ?? '').trim();
    if (icDph.isNotEmpty && !RegExp(r'^[A-Za-z]{2}\d{8,12}$').hasMatch(icDph.replaceAll(RegExp(r'\s'), ''))) {
      e['icDph'] = 'A VAT number looks like GB123456789, or leave it empty';
    }
    if ((_f['streetNumber'] ?? '').trim().isEmpty) e['streetNumber'] = t.pick('Ulica a číslo sú povinné', 'Street and number are required');
    if ((_f['city'] ?? '').trim().isEmpty) e['city'] = t.pick('Mesto je povinné', 'City is required');
    final zip = _f['zipcode'] ?? '';
    if (zip.trim().isEmpty) {
      e['zipcode'] = 'Postcode is required';
    } else if (_uk && !RegExp(r'^[A-Z]{1,2}[0-9][A-Z0-9]? ?[0-9][A-Z]{2}\$', caseSensitive: false).hasMatch(zip.trim())) {
      e['zipcode'] = 'Enter a valid UK postcode, e.g. SW1A 1AA';
    }
    if ((_f['countryCode'] ?? '').trim().isEmpty) e['countryCode'] = t.pick('Krajina je povinná', 'Country is required');
    setState(() => _errors = e);
    return e.isEmpty;
  }

  Future<void> _submit() async {
    final t = ref.read(stringsProvider);
    if (!_validate(t)) return;
    setState(() => _saving = true);
    try {
      final payload = <String, dynamic>{
        'billingSubjectType': _f['subjectType'],
        'companyName': _f['companyName']!.trim(),
        'streetNumber': _f['streetNumber']!.trim(),
        'city': _f['city']!.trim(),
        'zipcode': _f['zipcode']!.trim(),
        'countryCode': _f['countryCode']!.trim().toUpperCase(),
        if (_business) 'ico': _f['ico']!.trim(),
        if (_business) 'dic': _f['dic']!.trim(),
        'lang': t.lang,
      };
      final icDph = (_f['icDph'] ?? '').replaceAll(RegExp(r'\s'), '').toUpperCase();
      if (icDph.isNotEmpty) payload['icDph'] = icDph;
      final saved = await hostRepo.updateAccount(payload);
      if (!mounted) return;
      setState(() {
        _f = _toForm(asMap(saved['billing']));
        _formKey++;
      });
      widget.onSaved(saved);
      toast(context, t.pick('Fakturačné údaje boli uložené.', 'Billing details saved.'));
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final sm = MediaQuery.sizeOf(context).width >= 640;
    final business = _business;
    final lookupBusy = _lookupStatus == 'loading';

    Widget input(String key, String label, {String? ph, TextInputType? kb, bool enabled = true, int? max, bool upper = false}) => _Labelled(
          label: label,
          caps: false,
          value: _f[key] ?? '',
          placeholder: ph,
          keyboard: kb,
          enabled: enabled && (!lookupBusy || key == 'ico'),
          error: _errors[key],
          maxLength: max,
          upper: upper,
          onChanged: (v) => _set(key, v),
        );

    Widget radio(String value, String label) => InkWell(
          onTap: () => setState(() => _f['subjectType'] = value),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_f['subjectType'] == value ? Icons.radio_button_checked : Icons.radio_button_off, size: 20, color: _forest),
            const SizedBox(width: 8),
            Text(label, style: AppText.inter(size: 14, weight: FontWeight.w600, color: _forest)),
          ]),
        );

    Widget cols(List<Widget> items, int n) => n == 1 || !sm
        ? Column(children: [for (var i = 0; i < items.length; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 16), child: SizedBox(width: double.infinity, child: items[i]))])
        : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [for (var i = 0; i < items.length; i++) ...[if (i > 0) const SizedBox(width: 16), Expanded(child: items[i])]]);

    return Container(
      key: ValueKey(_formKey),
      margin: const EdgeInsets.only(top: 20),
      padding: EdgeInsets.all(sm ? 20 : 16),
      decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(t.pick('Fakturovať ako', 'Billing as'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
          radio('business', t.pick('Firma (má IČO)', 'Business (has IČO)')),
          radio('individual', t.pick('Fyzická osoba (bez IČO)', 'Individual (no IČO)')),
        ]),
        const SizedBox(height: 16),
        input('companyName', business ? t.pick('Názov spoločnosti', 'Company name') : t.pick('Celé právne meno', 'Full legal name'), ph: business ? 'UK Stay Hub Ltd' : t.pick('Vaše celé meno', 'Your full legal name')),
        if (business) ...[
          const SizedBox(height: 16),
          cols([
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              input('ico', 'Company number', ph: '01234567', upper: true),
              if (_lookupStatus != 'idle') Padding(padding: const EdgeInsets.only(top: 6), child: Text(_lookupMessage, style: AppText.inter(size: 12, color: _lookupStatus == 'success' ? const Color(0xFF15803D) : AppColors.neutral500))),
            ]),
            input('dic', 'UTR (tax reference)', ph: '1234567890', kb: TextInputType.number),
          ], 2),
          const SizedBox(height: 16),
          input('icDph', 'VAT number (optional)', ph: 'GB123456789', upper: true),
        ],
        const SizedBox(height: 16),
        input('streetNumber', t.pick('Ulica a číslo', 'Street and number'), ph: '221B Baker Street'),
        const SizedBox(height: 16),
        cols([
          input('city', t.pick('Mesto', 'Town / city'), ph: 'London'),
          input('zipcode', 'Postcode', ph: 'NW1 6XE', upper: true),
          input('countryCode', t.pick('Kód krajiny', 'Country code'), ph: 'GB', max: 2, upper: true),
        ], 3),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _saving || lookupBusy ? null : _submit,
            icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const SizedBox.shrink(),
            label: Text(_saving ? t.pick('Ukladám…', 'Saving…') : t.pick('Uložiť fakturačné údaje', 'Save billing details'), style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700)),
            style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ),
      ]),
    );
  }
}
