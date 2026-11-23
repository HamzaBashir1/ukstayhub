import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../state/auth.dart';
import '../../widgets/chrome.dart';
import '../../widgets/common.dart';
import '../../widgets/brand_logo_mark.dart';

const _green = Color(0xFF238869);
const _greenHover = Color(0xFF1D6F56);
const _forest = Color(0xFF163C2E);
const _label = Color(0xFF1A3A2E);
const _body = Color(0xFF4A5568);
const _border = Color(0xFFD9DEDB);
const _cardBorder = Color(0xFFE6E8E3);
const _panelBg = Color(0xFFFFFEF9);

Widget _logo(double size) => StayHubMark(size: size);

/// login/component/login.js, Signup.js and ForgetPassword.js share one layout: a
/// rounded card with a brand panel (from 1024px) beside the form panel.
class _AuthCard extends ConsumerWidget {
  const _AuthCard({required this.title, this.titleWidget, this.subtitle, required this.children});
  final String title;
  final Widget? titleWidget;
  final String? subtitle;
  final List<Widget> children;

  Widget _feature(IconData icon, String title, String desc) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 32,
          height: 32,
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), shape: BoxShape.circle),
          child: Icon(icon, size: 16, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.inter(size: 14, weight: FontWeight.w500, color: Colors.white)),
            Text(desc, style: AppText.inter(size: 13, color: Colors.white.withValues(alpha: 0.65))),
          ]),
        ),
      ]);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final width = MediaQuery.sizeOf(context).width;
    final lg = width >= 1024;
    final xl = width >= 1280;
    final sm = width >= 640;
    final md = width >= 768;

    final brand = Container(
      padding: EdgeInsets.all(xl ? 48 : 40),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_forest, Color(0xFF1A3A2E), Color(0xFF214F3D)]),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        InkWell(
          onTap: () => context.go('/'),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withValues(alpha: 0.15))),
              child: _logo(38),
            ),
            const SizedBox(width: 12),
            Text('UK Stay Hub', style: AppText.fraunces(size: 24, weight: FontWeight.w600, color: Colors.white)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('Hero_Accommodation', 'Cena, ktorú vidíte,'), style: AppText.fraunces(size: xl ? 36 : 30, weight: FontWeight.w600, color: Colors.white, height: 1.25)),
            Text(t('Hero_WithinReach', 'je cena, ktorú zaplatíte.'), style: AppText.fraunces(size: xl ? 36 : 30, weight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.85), height: 1.25)),
            const SizedBox(height: 16),
            Text(t('Hero_Subtitle', ''), style: AppText.inter(size: 15, color: Colors.white.withValues(alpha: 0.75), height: 1.625)),
          ]),
        ),
        Column(children: [
          _feature(Icons.check_circle_outline, t('Feature_VerifiedHosts_Title', ''), t('Feature_VerifiedHosts_Desc', '')),
          const SizedBox(height: 16),
          _feature(Icons.shield_outlined, t('Why_Secure_Title', ''), t('Why_Secure_Desc', '')),
        ]),
      ]),
    );

    final form = Container(
      color: _panelBg,
      padding: EdgeInsets.all(lg ? 48 : (sm ? 40 : 24)),
      child: AutofillGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: () => context.canPop() ? context.pop() : context.go('/'),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.chevron_left, size: 16, color: _green),
              const SizedBox(width: 6),
              Text(t('Back', 'Späť'), style: AppText.inter(size: 14, weight: FontWeight.w500, color: _green)),
            ]),
          ),
          if (!lg) ...[
            const SizedBox(height: 24),
            Center(
              child: InkWell(
                onTap: () => context.go('/'),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.neutral200),
                    gradient: const LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.white, Color(0xFFD0D5DD)]),
                  ),
                  child: _logo(48),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
          SizedBox(height: lg ? 32 : 24),
          SizedBox(
            width: double.infinity,
            child: Column(crossAxisAlignment: lg ? CrossAxisAlignment.start : CrossAxisAlignment.center, children: [
              titleWidget ??
                  Text(title, textAlign: lg ? TextAlign.left : TextAlign.center, style: AppText.fraunces(size: md ? 30 : 24, weight: FontWeight.w600, color: _forest, height: 1.25)),
              if (subtitle != null) ...[
                const SizedBox(height: 8),
                Text(subtitle!, textAlign: lg ? TextAlign.left : TextAlign.center, style: AppText.inter(size: md ? 16 : 14, color: _body, height: 1.5)),
              ],
            ]),
          ),
          const SizedBox(height: 32),
          Align(
            alignment: lg ? Alignment.centerLeft : Alignment.center,
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 448), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)),
          ),
        ]),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: const StayHubHeader(),
      endDrawer: const StayHubDrawer(),
      body: SingleChildScrollView(
        child: Column(children: [
          Padding(
          padding: EdgeInsets.fromLTRB(lg ? 32 : (sm ? 24 : 16), 24, lg ? 32 : (sm ? 24 : 16), 80),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1024),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: _cardBorder),
                  boxShadow: const [BoxShadow(color: Color(0x1A163C2E), blurRadius: 40, offset: Offset(0, 8))],
                ),
                child: lg ? IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: brand), Expanded(child: form)])) : form,
              ),
            ),
          ),
        ),
          const StayHubFooter(),
        ]),
      ),
    );
  }
}

/// Web input: rounded-xl, #D9DEDB border, green focus border + 2px ring at 20%.
class _AuthInput extends StatefulWidget {
  const _AuthInput({required this.controller, this.hint, this.password = false, this.keyboard, this.autofill, this.action, this.onSubmitted});
  final TextEditingController controller;
  final String? hint;
  final bool password;
  final TextInputType? keyboard;
  final Iterable<String>? autofill;
  final TextInputAction? action;
  final VoidCallback? onSubmitted;

  @override
  State<_AuthInput> createState() => _AuthInputState();
}

class _AuthInputState extends State<_AuthInput> {
  final _focus = FocusNode();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: focused ? _green : _border),
        boxShadow: focused ? [BoxShadow(color: _green.withValues(alpha: 0.2), spreadRadius: 2)] : null,
      ),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            obscureText: widget.password && _obscure,
            keyboardType: widget.keyboard,
            autofillHints: widget.autofill,
            textInputAction: widget.action,
            onSubmitted: widget.onSubmitted == null ? null : (_) => widget.onSubmitted!(),
            style: AppText.inter(size: 15, color: const Color(0xFF111827)),
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: AppText.inter(size: 15, color: const Color(0xFF9CA3AF)),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isDense: true,
              contentPadding: EdgeInsets.fromLTRB(16, 15, widget.password ? 0 : 16, 15),
            ),
          ),
        ),
        if (widget.password)
          InkWell(
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(12)),
            onTap: () => setState(() => _obscure = !_obscure),
            child: SizedBox(width: 48, height: 50, child: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20, color: const Color(0xFF94A3B8))),
          ),
      ]),
    );
  }
}

Widget _fieldLabel(String text, {bool required = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text.rich(TextSpan(children: [
        TextSpan(text: text, style: AppText.inter(size: 14, weight: FontWeight.w500, color: _label)),
        if (required) TextSpan(text: ' *', style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFFEF4444))),
      ])),
    );

class _AuthButton extends StatelessWidget {
  const _AuthButton({required this.label, required this.loading, required this.onPressed});
  final String label;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
        color: _green,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          hoverColor: _greenHover,
          onTap: loading ? null : onPressed,
          child: Container(
            height: 54,
            alignment: Alignment.center,
            child: loading
                ? const SizedBox(width: 25, height: 25, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                : Text(label, style: AppText.inter(size: 16, weight: FontWeight.w500, color: Colors.white)),
          ),
        ),
      );
}

Widget _linkText(String text, VoidCallback onTap) => GestureDetector(
      onTap: onTap,
      child: Text(text, style: AppText.inter(size: 14, weight: FontWeight.w500, color: _green)),
    );

bool _validEmail(String s) => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(s);

// ───────────────────────────── Login ─────────────────────────────
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.redirect});
  final String? redirect;
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _remember = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final t = ref.read(stringsProvider);
    if (_email.text.trim().isEmpty) return toast(context, t('emailRequired', 'E-mail je povinný'), error: true);
    if (_password.text.isEmpty) return toast(context, t('Passwordisrequired', 'Heslo je povinné'), error: true);
    setState(() => _loading = true);
    try {
      final mustChange = await ref.read(authProvider.notifier).login(_email.text, _password.text, t.lang);
      if (!mounted) return;
      final auth = ref.read(authProvider);
      if (mustChange) {
        toast(context, t.pick('Nastavte si vlastné heslo — to, ktoré sme vám poslali, je dočasné.', 'Please set your own password — the one we emailed you is temporary.'));
        context.go('/guest?changePassword=1');
      } else if (widget.redirect != null && widget.redirect!.startsWith('/')) {
        context.go(widget.redirect!);
      } else {
        context.go(auth.isHost ? '/host' : '/');
      }
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    return _AuthCard(
      title: t('Logintoyouraccount', 'Prihláste sa do svojho účtu'),
      subtitle: t('WelcomebackPleaseenteryourdetails', 'Vitajte späť! Zadajte svoje údaje.'),
      children: [
        _fieldLabel(t('email', 'E-mail'), required: true),
        _AuthInput(controller: _email, hint: t('input_placeholder', 'you@example.co.uk'), keyboard: TextInputType.emailAddress, autofill: const [AutofillHints.email, AutofillHints.username], action: TextInputAction.next),
        const SizedBox(height: 20),
        _fieldLabel(t('Password', 'Heslo'), required: true),
        _AuthInput(controller: _password, hint: '••••••••', password: true, autofill: const [AutofillHints.password], action: TextInputAction.done, onSubmitted: _submit),
        const SizedBox(height: 20),
        Row(children: [
          InkWell(
            onTap: () => setState(() => _remember = !_remember),
            child: Row(children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(color: _remember ? _green : const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(4), border: Border.all(color: _remember ? _green : _border)),
                child: _remember ? const Icon(Icons.check, size: 12, color: Colors.white) : null,
              ),
              const SizedBox(width: 12),
              Text(t('Rememberme', 'Zapamätať si ma'), style: AppText.inter(size: 14, color: _body)),
            ]),
          ),
          const Spacer(),
          _linkText(t('Forgotpassword', 'Zabudli ste heslo?'), () => context.push('/zabudnute-heslo')),
        ]),
        const SizedBox(height: 20),
        _AuthButton(label: t('login', 'Prihlásiť sa'), loading: _loading, onPressed: _submit),
        const SizedBox(height: 24),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('${t('Donthaveanaccount', 'Nemáte účet?')} ', style: AppText.inter(size: 14, color: _body)),
          _linkText(t('Registerhere', 'Zaregistrujte sa'), () => context.pushReplacement('/registracia')),
        ]),
      ],
    );
  }
}

// ───────────────────────────── Signup ─────────────────────────────
class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});
  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _name = TextEditingController();
  final _last = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String _gender = '';
  String _role = 'guest';
  bool _loading = false;
  bool _sent = false;
  Timer? _redirect;

  @override
  void dispose() {
    _redirect?.cancel();
    for (final c in [_name, _last, _email, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  bool _validate(Strings t) {
    String? error;
    if (_name.text.isEmpty) {
      error = '${t('FirstName', 'Meno')} ${t('isRequired', 'je povinné')}';
    } else if (_last.text.isEmpty) {
      error = '${t('LastName', 'Priezvisko')} ${t('isRequired', 'je povinné')}';
    } else if (_email.text.isEmpty) {
      error = '${t('EnterYourEmail', 'Zadajte e-mail')} ${t('isRequired', 'je povinné')}';
    } else if (!_validEmail(_email.text)) {
      error = t('EnterValidEmail', 'Zadajte platný e-mail');
    } else if (_password.text.isEmpty) {
      error = '${t('EnterPassword', 'Zadajte heslo')} ${t('isRequired', 'je povinné')}';
    } else if (_confirm.text.isEmpty) {
      error = '${t('ConfirmPassword', 'Potvrďte heslo')} ${t('isRequired', 'je povinné')}';
    } else if (_password.text != _confirm.text) {
      error = t('Passwordsdonotmatch', 'Heslá sa nezhodujú');
    } else if (_gender.isEmpty) {
      error = '${t('gender', 'Pohlavie')} ${t('isRequired', 'je povinné')}';
    }
    if (error != null) toast(context, error, error: true);
    return error == null;
  }

  Future<void> _submit() async {
    final t = ref.read(stringsProvider);
    if (!_validate(t)) return;
    setState(() => _loading = true);
    try {
      await ref.read(authProvider.notifier).register({
        'name': _name.text,
        'lastName': _last.text,
        'email': _email.text,
        'password': _password.text,
        'gender': _gender,
        'role': _role,
        'language': 'English',
        'lang': t.lang,
      });
      if (!mounted) return;
      toast(context, t('RegistrationsuccessfulCheckyouremailtoverifyyouraccount', 'Registrácia úspešná. Overte svoj účet v e-maile.'));
      setState(() => _sent = true);
      _redirect = Timer(const Duration(seconds: 5), () {
        if (mounted) context.go('/login');
      });
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    if (_sent) {
      // Signup/component/VerifyEmailMessage.js
      final sm = MediaQuery.sizeOf(context).width >= 640;
      return Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 576),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(t('Pleasecheckyouremailandverifyyouraccount', 'Skontrolujte e-mail a overte svoj účet'),
                      textAlign: TextAlign.center, style: AppText.fraunces(size: sm ? 30 : 24, weight: FontWeight.w600, color: _forest, height: 1.25)),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () => context.go('/login'),
                    style: FilledButton.styleFrom(backgroundColor: _green, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    child: Text(t('ComeBacktoLogin', 'Späť na prihlásenie'), style: AppText.inter(color: Colors.white, size: 16, weight: FontWeight.w500)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    Widget roleCard(String value, String title, String hint) {
      final on = _role == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _role = value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: on ? _green.withValues(alpha: 0.05) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: on ? _green : _border),
              boxShadow: on ? [BoxShadow(color: _green.withValues(alpha: 0.2), spreadRadius: 2)] : null,
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.inter(size: 15, weight: FontWeight.w500, color: _label)),
              Text(hint, style: AppText.inter(size: 13, color: const Color(0xFF6B7280))),
            ]),
          ),
        ),
      );
    }

    return _AuthCard(
      title: '',
      titleWidget: Builder(builder: (context) {
        final lg = MediaQuery.sizeOf(context).width >= 1024;
        final md = MediaQuery.sizeOf(context).width >= 768;
        return Text.rich(
          TextSpan(children: [
            TextSpan(text: '${t('create', 'Vytvoriť')} '),
            TextSpan(text: t('host', 'účet'), style: const TextStyle(color: _green)),
          ]),
          textAlign: lg ? TextAlign.left : TextAlign.center,
          style: AppText.fraunces(size: md ? 30 : 24, weight: FontWeight.w600, color: _forest, height: 1.25),
        );
      }),
      children: [
        _AuthInput(controller: _name, hint: t('FirstName', 'Meno'), autofill: const [AutofillHints.givenName], action: TextInputAction.next),
        const SizedBox(height: 20),
        _AuthInput(controller: _last, hint: t('LastName', 'Priezvisko'), autofill: const [AutofillHints.familyName], action: TextInputAction.next),
        const SizedBox(height: 20),
        _AuthInput(controller: _email, hint: t('EnterYourEmail', 'Zadajte e-mail'), keyboard: TextInputType.emailAddress, autofill: const [AutofillHints.email], action: TextInputAction.next),
        const SizedBox(height: 20),
        _AuthInput(controller: _password, hint: t('EnterPassword', 'Zadajte heslo'), password: true, autofill: const [AutofillHints.newPassword], action: TextInputAction.next),
        const SizedBox(height: 20),
        _AuthInput(controller: _confirm, hint: t('ConfirmPassword', 'Potvrďte heslo'), password: true, autofill: const [AutofillHints.newPassword], action: TextInputAction.done),
        const SizedBox(height: 20),
        _fieldLabel(t('gender', 'Pohlavie')),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _border)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _gender,
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down, size: 20, color: Color(0xFF94A3B8)),
              style: AppText.inter(size: 15, color: const Color(0xFF111827)),
              borderRadius: BorderRadius.circular(12),
              items: [
                DropdownMenuItem(value: '', child: Text(t('select', 'Vyberte'))),
                DropdownMenuItem(value: 'male', child: Text(t('Male', 'Muž'))),
                DropdownMenuItem(value: 'female', child: Text(t('Female', 'Žena'))),
                DropdownMenuItem(value: 'other', child: Text(t('other', 'Iné'))),
              ],
              onChanged: (v) => setState(() => _gender = v ?? ''),
            ),
          ),
        ),
        const SizedBox(height: 20),
        _fieldLabel(t.pick('Chcem', 'I want to')),
        Row(children: [
          roleCard('guest', t.pick('Rezervovať pobyty', 'Book stays'), t.pick('Cestovateľ', 'Traveller')),
          const SizedBox(width: 12),
          roleCard('host', t.pick('Prenajímať', 'Rent my place'), t.pick('Hostiteľ', 'Host')),
        ]),
        const SizedBox(height: 8),
        Text(t.pick('Medzi oboma môžete kedykoľvek prepnúť v menu.', 'You can switch between the two at any time from the menu.'), style: AppText.inter(size: 13, color: const Color(0xFF6B7280))),
        const SizedBox(height: 20),
        _AuthButton(label: t('signup', 'Registrovať sa'), loading: _loading, onPressed: _submit),
        const SizedBox(height: 20),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(t('alreadyhaveanaccount', 'Už máte účet?'), style: AppText.inter(size: 14, color: _body)),
          const SizedBox(width: 4),
          _linkText(t('login', 'Prihlásiť sa'), () => context.pushReplacement('/login')),
        ]),
      ],
    );
  }
}

// ───────────────────────────── Forgot / reset password ─────────────────────────────
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _email = TextEditingController();
  bool _loading = false;
  String _message = '';

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final t = ref.read(stringsProvider);
    final email = _email.text;
    if (email.isEmpty) {
      final m = t('Pleaseenteravalidemailaddress', 'Zadajte platnú e-mailovú adresu');
      setState(() => _message = m);
      return toast(context, m, error: true);
    }
    if (!_validEmail(email)) {
      final m = t('EnterValidEmail', 'Zadajte platný e-mail');
      setState(() => _message = m);
      return toast(context, m, error: true);
    }
    setState(() => _loading = true);
    try {
      await authRepo.requestPasswordReset(email, t.lang);
      if (!mounted) return;
      final m = t('Pleasecheckyouremailandresetthepassword', 'Skontrolujte e-mail a obnovte heslo');
      setState(() {
        _message = m;
        _email.clear();
      });
      toast(context, m);
    } catch (_) {
      if (!mounted) return;
      final m = t('SomethingwentwrongPleaseTryAgain', 'Niečo sa pokazilo. Skúste to znova.');
      setState(() => _message = m);
      toast(context, m, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    return _AuthCard(
      title: t('ResetthePasswordofAccount', 'Obnovenie hesla'),
      subtitle: t('Pleaseenteryouremailtoreceivetheresetlink', 'Zadajte e-mail a pošleme vám odkaz na obnovenie'),
      children: [
        _fieldLabel(t('emailAddress', 'E-mailová adresa'), required: true),
        _AuthInput(controller: _email, hint: t('input_placeholder', 'you@example.co.uk'), keyboard: TextInputType.emailAddress, autofill: const [AutofillHints.email], action: TextInputAction.done, onSubmitted: _submit),
        const SizedBox(height: 20),
        _AuthButton(label: t('SendResetLink', 'Odoslať odkaz'), loading: _loading, onPressed: _submit),
        if (_message.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(_message, textAlign: TextAlign.center, style: AppText.inter(size: 14, color: _green)),
        ],
        const SizedBox(height: 20),
        _linkText(t('login', 'Prihlásiť sa'), () => context.pushReplacement('/login')),
      ],
    );
  }
}

/// reset-password/[token]/ResetPasswordClient.js – centred icon, no card.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key, required this.token, this.role});
  final String token;
  final String? role;
  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _p1 = TextEditingController();
  final _p2 = TextEditingController();
  bool _loading = false;
  String _message = '';

  @override
  void dispose() {
    _p1.dispose();
    _p2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final t = ref.read(stringsProvider);
    if (_p1.text.isEmpty || _p2.text.isEmpty) return toast(context, t('AllFieldsAreRequired', 'Všetky polia sú povinné'), error: true);
    if (_p1.text != _p2.text) {
      setState(() => _message = t('Passwordsdonotmatch', 'Heslá sa nezhodujú'));
      return;
    }
    setState(() => _loading = true);
    try {
      await authRepo.resetPassword(widget.token, _p1.text, role: widget.role);
      if (!mounted) return;
      toast(context, t('SuccessfullyResetPassword', 'Heslo bolo úspešne obnovené'));
      context.go('/login');
    } catch (_) {
      if (!mounted) return;
      final m = t('SomethingwentwrongPleaseTryAgain', 'Niečo sa pokazilo. Skúste to znova.');
      setState(() => _message = m);
      toast(context, m, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _plainField(String label, TextEditingController c) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: label, style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFF111827))),
            TextSpan(text: ' *', style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFFEF4444))),
          ])),
        ),
        TextField(
          controller: c,
          obscureText: true,
          autofillHints: const [AutofillHints.newPassword],
          style: AppText.inter(size: 14, color: const Color(0xFF111827)),
          decoration: InputDecoration(
            hintText: '••••••••',
            isDense: true,
            filled: false,
            contentPadding: const EdgeInsets.all(10),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _green)),
          ),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final md = MediaQuery.sizeOf(context).width >= 768;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: const StayHubHeader(),
      endDrawer: const StayHubDrawer(),
      body: SingleChildScrollView(
        child: Column(children: [
          Padding(
          padding: EdgeInsets.fromLTRB(20, md ? 80 : 40, 20, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 448),
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.neutral200),
                        gradient: const LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.white, Color(0xFFD0D5DD)]),
                      ),
                      child: _logo(48),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(t('ResetthePasswordofAccount', 'Obnovenie hesla'), textAlign: TextAlign.center, style: AppText.inter(size: md ? 30 : 24, weight: FontWeight.w600, color: const Color(0xFF101828))),
                  const SizedBox(height: 12),
                  Text(t('Pleaseenteryournewpassword', 'Zadajte nové heslo'), textAlign: TextAlign.center, style: AppText.inter(size: md ? 16 : 14, color: const Color(0xFF475467))),
                  const SizedBox(height: 32),
                  _plainField(t('EnterNewPassword', 'Nové heslo'), _p1),
                  SizedBox(height: md ? 24 : 16),
                  _plainField(t('ConfirmPassword', 'Potvrďte heslo'), _p2),
                  if (_message.isNotEmpty) ...[
                    SizedBox(height: md ? 24 : 16),
                    Text(_message, textAlign: TextAlign.center, style: AppText.inter(size: 16, color: const Color(0xFFEF4444))),
                  ],
                  SizedBox(height: md ? 24 : 16),
                  Material(
                    color: _green,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _loading ? null : _submit,
                      child: Container(
                        height: 54,
                        alignment: Alignment.center,
                        child: _loading
                            ? const SizedBox(width: 25, height: 25, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                            : Text(t('Resetthepassword', 'Obnoviť heslo'), style: AppText.inter(size: 18, color: Colors.white)),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
          const StayHubFooter(),
        ]),
      ),
    );
  }
}
