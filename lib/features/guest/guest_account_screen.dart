import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/storage.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/repo.dart';
import '../../state/auth.dart';
import '../../state/providers.dart';
import '../../widgets/chrome.dart';
import '../../widgets/common.dart';
import '../../widgets/stay_card.dart';

/// guest/GuestLayout.js – Personal details · Saved · Bookings · Trip history.
class GuestAccountScreen extends ConsumerStatefulWidget {
  const GuestAccountScreen({super.key, this.initialTab = 'profile', this.forcePasswordChange = false});
  final String initialTab;
  final bool forcePasswordChange;
  @override
  ConsumerState<GuestAccountScreen> createState() => _GuestAccountScreenState();
}

class _GuestAccountScreenState extends ConsumerState<GuestAccountScreen> with SingleTickerProviderStateMixin {
  static const _tabs = ['profile', 'favorites', 'bookings', 'stays'];
  late final TabController _c = TabController(
    length: 4,
    vsync: this,
    initialIndex: _tabs.indexOf(widget.initialTab).clamp(0, 3),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final auth = ref.watch(authProvider);
    return Scaffold(
      backgroundColor: AppColors.cream,
      appBar: const StayHubHeader(logo: true),
      endDrawer: const StayHubDrawer(),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Row(children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: AppColors.greenSoft,
              child: Text(initials(auth.name), style: AppText.inter(size: 18, weight: FontWeight.w700, color: Colors.white)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${t.pick('Vitajte späť', 'Welcome back')}${auth.name.isEmpty ? '' : ', ${auth.name.split(' ').first}'}',
                    style: AppText.fraunces(size: 20)),
                Text(t.pick('Spravujte svoj účet a nadchádzajúce cesty.', 'Manage your account and upcoming trips.'),
                    style: AppText.inter(size: 13, color: AppColors.neutral500)),
              ]),
            ),
          ]),
        ),
        TabBar(
          controller: _c,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: AppColors.forest,
          unselectedLabelColor: AppColors.neutral500,
          indicatorColor: AppColors.green,
          labelStyle: AppText.inter(size: 14, weight: FontWeight.w700),
          unselectedLabelStyle: AppText.inter(size: 14, weight: FontWeight.w500),
          tabs: [
            Tab(icon: const Icon(Icons.person_outline, size: 20), text: t.pick('Osobné údaje', 'Personal Details')),
            Tab(icon: const Icon(Icons.favorite_border, size: 20), text: t.pick('Uložené', 'Saved Stays')),
            Tab(icon: const Icon(Icons.event_available_outlined, size: 20), text: t.pick('Rezervácie', 'My Bookings')),
            Tab(icon: const Icon(Icons.history, size: 20), text: t.pick('Moje cesty', 'Trip History')),
          ],
        ),
        Expanded(
          child: TabBarView(controller: _c, children: [
            _ProfileTab(forcePasswordChange: widget.forcePasswordChange),
            const _FavoritesTab(),
            const _BookingsTab(past: false),
            const _BookingsTab(past: true),
          ]),
        ),
      ]),
    );
  }
}

// ───────────────────────────── Profile ─────────────────────────────
class _ProfileTab extends ConsumerStatefulWidget {
  const _ProfileTab({required this.forcePasswordChange});
  final bool forcePasswordChange;
  @override
  ConsumerState<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends ConsumerState<_ProfileTab> {
  final _name = TextEditingController();
  final _last = TextEditingController();
  final _phone = TextEditingController();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  final _email = TextEditingController();
  bool _saving = false;
  bool _changing = false;
  bool _editing = false;
  late bool _showSecurity = widget.forcePasswordChange;
  String _gender = 'other';
  String _language = 'English';

  void _readProfile(Json p) {
    if (asString(p['name']).isNotEmpty) _name.text = asString(p['name']);
    if (asString(p['lastName']).isNotEmpty) _last.text = asString(p['lastName']);
    final ph = asString(p['phoneNumber'] ?? p['phone']);
    if (ph.isNotEmpty) _phone.text = ph;
    final g = asString(p['gender']);
    if (const ['female', 'male', 'other'].contains(g)) _gender = g;
    final l = asString(p['language']);
    if (l == 'English') _language = l;
  }

  @override
  void initState() {
    super.initState();
    _readProfile(ref.read(authProvider).user ?? const {});
    guestRepo.me().then((m) {
      final p = asMap(m['profile'] ?? m['user'] ?? m['data'] ?? m);
      if (!mounted || p.isEmpty) return;
      setState(() => _readProfile(p));
    }).catchError((_) {});
  }

  @override
  void dispose() {
    for (final c in [_name, _last, _phone, _current, _next, _confirm, _email]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final t = ref.read(stringsProvider);
    final phone = _phone.text.replaceAll(RegExp(r'\s'), '');
    if (_name.text.trim().isEmpty || _last.text.trim().isEmpty) {
      return toast(context, t.pick('Zadajte meno a priezvisko.', 'Enter your first and last name.'), error: true);
    }
    if (!RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(phone)) {
      return toast(context, t.pick('Zadajte platné telefónne číslo v medzinárodnom formáte.', 'Enter a valid international phone number.'), error: true);
    }
    setState(() => _saving = true);
    try {
      final patch = {
        'name': _name.text.trim(),
        'lastName': _last.text.trim(),
        'phoneNumber': phone,
        'gender': _gender,
        'language': _language,
      };
      await guestRepo.updateMe(patch);
      await ref.read(authProvider.notifier).updateUser(patch);
      if (mounted) {
        setState(() => _editing = false);
        toast(context, t.pick('Profil bol aktualizovaný.', 'Profile updated.'));
      }
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changePassword() async {
    final t = ref.read(stringsProvider);
    if (_next.text.length < 8) return toast(context, t.pick('Nové heslo musí mať aspoň 8 znakov.', 'New password must have at least 8 characters.'), error: true);
    if (_next.text != _confirm.text) return toast(context, t.pick('Nové heslá sa nezhodujú.', 'New passwords do not match.'), error: true);
    setState(() => _changing = true);
    try {
      await guestRepo.changePassword(_current.text, _next.text);
      // Web logs the guest out after a password change.
      if (!mounted) return;
      toast(context, t.pick('Heslo bolo zmenené. Prihláste sa znova.', 'Password changed. Please log in again.'));
      await ref.read(authProvider.notifier).logout();
      if (mounted) context.go('/login');
    } catch (e) {
      if (mounted) {
        toast(context, errorText(e), error: true);
        setState(() => _changing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    return ListView(padding: const EdgeInsets.all(20), children: [
      if (widget.forcePasswordChange)
        Container(
          margin: const EdgeInsets.only(bottom: 20),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFFDE68A))),
          child: Text(
            t.pick('Prihlásili ste sa heslom z e-mailu. Z bezpečnostných dôvodov si ho prosím zmeňte.',
                'You signed in with the emailed password. Please change it now for your security.'),
            style: AppText.inter(size: 14, color: const Color(0xFF92400E)),
          ),
        ),
      _card(t.pick('Osobné údaje', 'Personal Details'), [
        Text(t.pick('Vaša identita a kontaktné informácie.', 'Your identity and contact information.'),
            style: AppText.inter(size: 13, color: AppColors.neutral500)),
        const SizedBox(height: 12),
        OutlineBtn(
          label: _editing ? t.pick('Zrušiť', 'Cancel') : t.pick('Upraviť', 'Edit'),
          icon: Icons.edit_outlined,
          height: 44,
          onPressed: () => setState(() => _editing = !_editing),
        ),
        const SizedBox(height: 16),
        StayHubField(label: t.pick('Meno', 'First name'), controller: _name, enabled: _editing),
        const SizedBox(height: 14),
        StayHubField(label: t.pick('Priezvisko', 'Last name'), controller: _last, enabled: _editing),
        const SizedBox(height: 14),
        StayHubField(label: 'Email', controller: _email..text = ref.watch(authProvider).email, enabled: false),
        const SizedBox(height: 14),
        StayHubField(label: t.pick('Telefón', 'Phone'), controller: _phone, keyboard: TextInputType.phone, hint: '+44 7700 900000', enabled: _editing),
        const SizedBox(height: 14),
        FieldLabel(t.pick('Pohlavie', 'Gender')),
        DropdownButtonFormField<String>(
          value: _gender,
          items: [
            DropdownMenuItem(value: 'female', child: Text(t.pick('Žena', 'Female'))),
            DropdownMenuItem(value: 'male', child: Text(t.pick('Muž', 'Male'))),
            DropdownMenuItem(value: 'other', child: Text(t.pick('Iné', 'Other'))),
          ],
          onChanged: _editing ? (v) => setState(() => _gender = v ?? _gender) : null,
        ),
        const SizedBox(height: 14),
        FieldLabel(t.pick('Jazyk', 'Language')),
        DropdownButtonFormField<String>(
          value: _language,
          items: const [
            DropdownMenuItem(value: 'English', child: Text('English (UK)')),
          ],
          onChanged: _editing ? (v) => setState(() => _language = v ?? _language) : null,
        ),
        if (_editing) ...[
          const SizedBox(height: 20),
          PrimaryButton(label: t.pick('Uložiť zmeny', 'Save changes'), loading: _saving, onPressed: _save),
        ],
      ]),
      const SizedBox(height: 20),
      OutlineBtn(
        label: t.pick('Heslo a bezpečnosť', 'Password and security'),
        icon: Icons.key_outlined,
        onPressed: () => setState(() => _showSecurity = !_showSecurity),
      ),
      if (_showSecurity) ...[
        const SizedBox(height: 12),
        _card(t.pick('Zmena hesla', 'Change password'), [
          StayHubField(label: t.pick('Aktuálne heslo', 'Current password'), controller: _current, password: true),
          const SizedBox(height: 14),
          StayHubField(label: t.pick('Nové heslo', 'New password'), controller: _next, password: true),
          const SizedBox(height: 14),
          StayHubField(label: t.pick('Potvrďte nové heslo', 'Confirm new password'), controller: _confirm, password: true),
          const SizedBox(height: 20),
          PrimaryButton(label: t.pick('Zmeniť heslo', 'Change password'), loading: _changing, onPressed: _changePassword),
        ]),
      ],
      const SizedBox(height: 20),
      // HostModeTeaser: same switch the drawer menu performs.
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: AppColors.forest, borderRadius: BorderRadius.circular(20)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.pick('Prepnite na hostiteľa', 'Switch to hosting'), style: AppText.fraunces(size: 19, color: Colors.white)),
          const SizedBox(height: 6),
          Text(t.pick('Spravujte svoje ubytovania a rezervácie.', 'Manage your properties and bookings.'),
              style: AppText.inter(size: 13, color: Colors.white70)),
          const SizedBox(height: 14),
          OutlineBtn(
            label: t.pick('Prepnúť režim', 'Switch mode'),
            icon: Icons.arrow_forward,
            color: AppColors.forest,
            borderColor: Colors.white,
            onPressed: () async {
              try {
                await ref.read(authProvider.notifier).switchMode('host', t.lang);
                if (context.mounted) context.go('/host');
              } catch (e) {
                if (context.mounted) toast(context, errorText(e), error: true);
              }
            },
          ),
        ]),
      ),
      const SizedBox(height: 20),
      OutlineBtn(
        label: t('logout', 'Odhlásiť sa'),
        icon: Icons.logout,
        color: AppColors.red,
        onPressed: () async {
          await ref.read(authProvider.notifier).logout();
          if (context.mounted) context.go('/');
        },
      ),
    ]);
  }

  Widget _card(String title, List<Widget> children) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.neutral200)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: AppText.fraunces(size: 19)),
          const SizedBox(height: 16),
          ...children,
        ]),
      );
}

// ───────────────────────────── Favorites ─────────────────────────────
class _FavoritesTab extends ConsumerWidget {
  const _FavoritesTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(favoriteListingsProvider);
    return RefreshIndicator(
      color: AppColors.green,
      onRefresh: () => ref.refresh(favoriteListingsProvider.future),
      child: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ListView(children: [ErrorView(error: e, message: errorText(e), onRetry: () => ref.invalidate(favoriteListingsProvider))]),
        data: (items) => items.isEmpty
            ? ListView(padding: const EdgeInsets.all(20), children: [
                EmptyBox(t.pick('Zatiaľ nemáte uložené žiadne ubytovania.', 'You have no saved stays yet.'), icon: Icons.favorite_border),
                const SizedBox(height: 16),
                PrimaryButton(label: t('ShowAllListing', 'Zobraziť všetky ubytovania'), onPressed: () => context.push('/mapa')),
              ])
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 20),
                itemBuilder: (_, i) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  StayCard(listing: items[i]),
                  const SizedBox(height: 8),
                  OutlineBtn(
                    label: t.pick('Odstrániť', 'Remove'),
                    icon: Icons.delete_outline,
                    color: AppColors.red,
                    height: 42,
                    onPressed: () async {
                      try {
                        await ref.read(favoritesProvider.notifier).toggle(items[i].id);
                        if (context.mounted) toast(context, t.pick('Odstránené z uložených.', 'Removed from saved stays.'));
                      } catch (e) {
                        if (context.mounted) toast(context, errorText(e), error: true);
                      }
                    },
                  ),
                ]),
              ),
      ),
    );
  }
}

// ───────────────────────────── Bookings ─────────────────────────────
class _BookingsTab extends ConsumerWidget {
  const _BookingsTab({required this.past});
  final bool past;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(myReservationsProvider);
    return RefreshIndicator(
      color: AppColors.green,
      onRefresh: () => ref.refresh(myReservationsProvider.future),
      child: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ListView(children: [ErrorView(error: e, message: errorText(e), onRetry: () => ref.invalidate(myReservationsProvider))]),
        data: (all) {
          final items = all.where((r) => past ? (r.isPast || r.cancelled) : (!r.isPast && !r.cancelled)).toList()
            ..sort((a, b) => past
                ? (b.checkIn ?? DateTime(0)).compareTo(a.checkIn ?? DateTime(0))
                : (a.checkIn ?? DateTime(0)).compareTo(b.checkIn ?? DateTime(0)));
          if (items.isEmpty) {
            return ListView(padding: const EdgeInsets.all(20), children: [
              EmptyBox(
                past ? t.pick('Zatiaľ žiadne cesty.', 'No trips yet.') : t.pick('Nemáte žiadne nadchádzajúce rezervácie.', 'You have no upcoming bookings.'),
                icon: Icons.event_busy_outlined,
              ),
            ]);
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (_, i) => _BookingCard(r: items[i], past: past),
          );
        },
      ),
    );
  }
}

class _BookingCard extends ConsumerWidget {
  const _BookingCard({required this.r, required this.past});
  final GuestReservation r;
  final bool past;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final l = r.listing;
    final img = l.images.isEmpty ? '' : l.images.first;
    final (label, fg, bg) = r.cancelled
        ? (t.pick('Zrušené', 'Cancelled'), AppColors.neutral600, AppColors.neutral100)
        : r.approval == 'approved' || r.paymentStatus == 'paid'
            ? (t.pick('Potvrdené', 'Confirmed'), AppColors.green, AppColors.mint)
            : (t.pick('Čaká na hostiteľa', 'Awaiting the host'), const Color(0xFFB45309), const Color(0xFFFFFBEB));
    final nights = r.checkIn == null || r.checkOut == null ? 0 : r.checkOut!.difference(r.checkIn!).inDays;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: l.slug.isEmpty ? null : () => context.push('/listings/${l.slug}'),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.neutral200)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(width: 84, height: 72, child: NetImage(cloudinary(img, width: 260), cacheWidth: 260)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.name(t.lang).isEmpty ? t.pick('Ubytovanie', 'Stay') : l.name(t.lang),
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.fraunces(size: 16, color: AppColors.forestListing)),
                  const SizedBox(height: 4),
                  Text(rangeLabel(r.checkIn, r.checkOut, t.lang), style: AppText.inter(size: 13, color: AppColors.neutral600)),
                  Text(
                    '${r.persons} ${t.pick('hostia', 'guests')}${nights > 0 ? ' · $nights ${t.pick('nocí', nights == 1 ? 'night' : 'nights')}' : ''}',
                    style: AppText.inter(size: 13, color: AppColors.neutral600),
                  ),
                  const SizedBox(height: 6),
                  Pill(label, fg: fg, bg: bg),
                ]),
              ),
              Text(money(r.total, decimals: true), style: AppText.inter(size: 15, weight: FontWeight.w700)),
            ]),
            if (!r.cancelled) ...[
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlineBtn(
                    label: t('DownloadReceipt', t.pick('Potvrdenie', 'Receipt')),
                    icon: Icons.receipt_long_outlined,
                    height: 42,
                    onPressed: () async {
                      final token = await SecureStore.reservationToken(r.id);
                      final url = '${bookingRepo.receiptUrl(r.id, t.lang)}${token == null ? '' : '&reservationToken=${Uri.encodeComponent(token)}'}';
                      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                    },
                  ),
                ),
                if (!past) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlineBtn(
                      label: t.pick('Zrušiť', 'Cancel'),
                      color: AppColors.red,
                      height: 42,
                      onPressed: () => _cancel(context, ref, r),
                    ),
                  ),
                ] else ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlineBtn(
                      label: t.pick('Ohodnotiť', 'Review'),
                      icon: Icons.star_outline,
                      height: 42,
                      onPressed: () => context.push('/review/${l.id.isEmpty ? r.accommodationId : l.id}'),
                    ),
                  ),
                ],
              ]),
            ],
          ]),
        ),
      ),
    );
  }

  /// CancelBookingButton.js – preview the refund first, then confirm.
  Future<void> _cancel(BuildContext context, WidgetRef ref, GuestReservation r) async {
    final t = ref.read(stringsProvider);
    Json? preview;
    try {
      preview = await bookingRepo.cancellationPreview(r.id);
    } catch (e) {
      if (context.mounted) toast(context, errorText(e), error: true);
      return;
    }
    if (!context.mounted) return;
    final refundCents = asInt(preview['refundCents'] ?? preview['refundAmountCents']);
    final pct = asInt(preview['refundPercent']);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.pick('Zrušiť rezerváciu?', 'Cancel booking?'), style: AppText.fraunces(size: 20)),
        content: Text(
          '${t.pick('Vrátime vám', 'You will be refunded')} ${moneyCents(refundCents)}${pct > 0 ? ' ($pct %)' : ''}.',
          style: AppText.inter(size: 15),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.pick('Ponechať', 'Keep'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.pick('Zrušiť rezerváciu', 'Cancel booking')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await bookingRepo.cancel(r.id);
      ref.invalidate(myReservationsProvider);
      if (context.mounted) toast(context, t.pick('Rezervácia bola zrušená.', 'Booking cancelled.'));
    } catch (e) {
      if (context.mounted) toast(context, errorText(e), error: true);
    }
  }
}
