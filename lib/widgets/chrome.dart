import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/auth.dart';
import '../state/search.dart';
import 'common.dart';
import 'search_pickers.dart';
import 'brand_logo_mark.dart';
import '../features/search/search_screen.dart' show MobileSearchHeader;

/// Mobile header. Like the website, most pages use the search header
/// (HeroSearchForm2Mobile + MenuBar: P logo, search pill, burger); only the
/// home page, the guest account and the Stripe onboarding pages use
/// components/Header/MobileHeader.js (logo, language flag, avatar, burger) —
/// pass [logo] for those. Neither shows a back arrow; Android's back gesture
/// handles going back.
class StayHubHeader extends ConsumerWidget implements PreferredSizeWidget {
  const StayHubHeader({
    super.key,
    this.showBack = false,
    this.logo = false,
    this.background = AppColors.cream,
    this.compactSearch = false,
    this.mapSearch = false,
  });

  /// Kept so existing call sites compile; the website shows no back arrow.
  final bool showBack;

  /// Use the home-page style header (MobileHeader.js) instead of the search header.
  final bool logo;
  final Color background;

  /// Desktop only: swap the nav links for the compact search bar (Header.js
  /// does this once the hero search form scrolls out of view).
  final bool compactSearch;

  /// Desktop only: the /mapa header (listing-stay-map/component/Header.js),
  /// 96px tall with the location · dates · guests bar in the middle.
  final bool mapSearch;

  // preferredSize has no BuildContext, so the width comes from the window; the
  // Scaffold reads it again on every resize.
  static bool get _desktop {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return false;
    final v = views.first;
    return v.physicalSize.width / v.devicePixelRatio >= 1024;
  }

  @override
  Size get preferredSize => Size.fromHeight(_desktop ? (mapSearch ? 96 : 72) : (logo ? 60 : 90));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (context.lg) return _DesktopHeader(compactSearch: compactSearch, mapSearch: mapSearch);
    if (!logo) {
      // `sticky top-0 bg-white/80 px-2 py-4 backdrop-blur-md`, shadow 0 2px 4px rgba(26,58,46,.1).
      return Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Color(0x1A1A3A2E), blurRadius: 4, offset: Offset(0, 2))],
        ),
        child: const SafeArea(
          bottom: false,
          child: SizedBox(height: 90, child: Center(child: MobileSearchHeader())),
        ),
      );
    }
    final t = ref.watch(stringsProvider);
    final auth = ref.watch(authProvider);
    return Material(
      color: background,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              GestureDetector(
                onTap: () => context.go('/'),
                child: const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: StayHubLogo(height: 26),
                ),
              ),
              const Spacer(),
              const SizedBox(width: 8),
              if (auth.loggedIn) ...[
                InkWell(
                  onTap: () => _showAccountMenu(context, ref),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.35),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.neutral200),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 24,
                        height: 24,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(color: AppColors.greenSoft, shape: BoxShape.circle),
                        child: Text(initials(auth.name),
                            style: AppText.inter(size: 11, weight: FontWeight.w600, color: Colors.white)),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(auth.firstName.isEmpty ? t('Account', 'Účet') : auth.firstName,
                            overflow: TextOverflow.ellipsis, style: AppText.inter(size: 12, color: AppColors.neutral800)),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              Builder(
                builder: (ctx) => IconButton(
                  onPressed: () => Scaffold.of(ctx).openEndDrawer(),
                  icon: const Icon(Icons.menu_rounded, size: 26, color: AppColors.neutral700),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

Future<void> _showAccountMenu(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: AccountMenu(onClose: () => Navigator.of(ctx).pop()))),
  );
}

/// components/Header.js – the desktop header (lg and up).
class _DesktopHeader extends ConsumerWidget {
  const _DesktopHeader({required this.compactSearch, this.mapSearch = false});
  final bool compactSearch;
  final bool mapSearch;

  static const _accent = Color(0xFF4FBE9F);
  static const _cta = Color(0xFF33846C);
  static const _glow = [BoxShadow(color: Color(0xFF41C69F), blurRadius: 8.7)];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final auth = ref.watch(authProvider);

    Widget navLink(IconData icon, String label, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18, color: _accent),
            const SizedBox(width: 6),
            Text(label, style: AppText.inter(size: 16, weight: FontWeight.w500, color: const Color(0xFF374151))),
          ]),
        );

    final nav = Row(mainAxisSize: MainAxisSize.min, children: [
      navLink(Icons.location_on_outlined, t('findStay', 'Nájsť ubytovanie'), () => context.push('/mapa')),
      if (auth.loggedIn && auth.isHost) ...[
        const SizedBox(width: 32),
        navLink(Icons.home_outlined, t('listProperty', 'Pridať ubytovanie'), () => context.go('/host')),
      ],
    ]);

    final search = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 448),
      child: Row(children: [
        // DestinationPicker compact: type the place right in the header.
        Expanded(
          child: Container(
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFFE5E7EB)),
              boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: DestinationField(style: DestinationStyle.compact, onSubmitted: () => context.push('/mapa')),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: _cta,
          shape: const StadiumBorder(),
          shadowColor: const Color(0xFF41C69F),
          elevation: 3,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => context.push('/mapa'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
              child: Text(t('Header_SearchBtn', 'Hľadať'),
                  style: AppText.inter(size: 14, weight: FontWeight.w600, color: Colors.white)),
            ),
          ),
        ),
      ]),
    );

    final Widget account;
    if (auth.loggedIn) {
      account = PopupMenuButton<Never>(
        tooltip: '',
        offset: const Offset(0, 52),
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        constraints: const BoxConstraints.tightFor(width: 240),
        itemBuilder: (ctx) => [_RawMenuEntry(Padding(padding: const EdgeInsets.all(8), child: AccountMenu(onClose: () => Navigator.of(ctx).pop())))],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: _accent, shape: BoxShape.circle),
              child: Text(initials(auth.name), style: AppText.inter(size: 14, weight: FontWeight.w600, color: Colors.white)),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 192),
              child: Text(auth.name,
                  overflow: TextOverflow.ellipsis, style: AppText.inter(size: 14, weight: FontWeight.w500, color: AppColors.neutral900)),
            ),
          ]),
        ),
      );
    } else {
      account = Row(mainAxisSize: MainAxisSize.min, children: [
        DecoratedBox(
          decoration: const BoxDecoration(borderRadius: BorderRadius.all(Radius.circular(999)), boxShadow: _glow),
          child: Material(
            color: _cta,
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => context.push('/mapa'),
              child: Container(
                height: mapSearch ? 44 : 40,
                padding: EdgeInsets.symmetric(horizontal: mapSearch && !context.xl ? 16 : 20),
                alignment: Alignment.center,
                child: Text(
                    mapSearch && !context.xl ? t.pick('Hľadať', 'Search') : t('Header_FindAccommodation', 'Nájdi ubytovanie'),
                    style: AppText.inter(size: 14, weight: mapSearch ? FontWeight.w600 : FontWeight.w500, color: Colors.white)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        InkWell(
          onTap: () => context.push('/login'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Text(t('Header_LoginSecondary', 'Prihlásiť sa'),
                style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFF4B5563))),
          ),
        ),
      ]);
    }

    if (mapSearch) {
      final xl = context.xl;
      return Material(
        color: Colors.white.withValues(alpha: 0.95),
        child: Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFE7EFEB)))),
          child: SafeArea(
            bottom: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1940),
                child: SizedBox(
                  height: 95,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: context.vw >= 1536 ? 40 : (xl ? 32 : 20)),
                    child: Row(children: [
                      SizedBox(
                        width: 112,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: GestureDetector(
                            onTap: () => context.go('/'),
                            child: const StayHubLogo(height: 30),
                          ),
                        ),
                      ),
                      SizedBox(width: xl ? 24 : 16),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: const _MapSearchBar()),
                        ),
                      ),
                      SizedBox(width: xl ? 24 : 16),
                      account,
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.white,
      child: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1440),
            child: SizedBox(
              height: 72,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  GestureDetector(
                    onTap: () => context.go('/'),
                    child: const StayHubLogo(height: 28),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: compactSearch ? KeyedSubtree(key: const ValueKey('s'), child: search) : nav,
                        ),
                      ),
                    ),
                  ),
                  account,
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// listing-stay-map/component/StaySearchForm.js – the 68px pill in the /mapa header.
class _MapSearchBar extends ConsumerWidget {
  const _MapSearchBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final s = ref.watch(searchProvider);
    final g = s.guests;
    final xl = context.xl;

    Widget divider() => Container(width: 1, height: 24, color: const Color(0xFFE2E8F0));

    Widget segment({
      required int flex,
      required IconData icon,
      required String title,
      required bool filled,
      required String sub,
      required void Function(BuildContext) onTap,
      VoidCallback? onClear,
      Widget? trailing,
      double iconSize = 28,
      Color iconColor = AppColors.neutral300,
    }) =>
        Expanded(
          flex: flex,
          child: Builder(builder: (ctx) => InkWell(
            onTap: () => onTap(ctx),
            borderRadius: BorderRadius.circular(28),
            child: Padding(
              padding: EdgeInsets.only(left: 20, right: trailing == null ? 12 : 8),
              child: Row(children: [
                Icon(icon, size: iconSize, color: iconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.inter(
                            size: xl ? 18 : 16,
                            weight: FontWeight.w600,
                            color: filled ? AppColors.neutral900 : AppColors.neutral400,
                            height: 1.2)),
                    const SizedBox(height: 4),
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.inter(size: 14, weight: FontWeight.w300, color: AppColors.neutral500, height: 1)),
                  ]),
                ),
                if (onClear != null)
                  InkWell(
                    onTap: onClear,
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: const BoxDecoration(color: AppColors.neutral200, shape: BoxShape.circle),
                      child: const Icon(Icons.close, size: 14, color: AppColors.neutral700),
                    ),
                  ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing],
              ]),
            ),
          )),
        );

    final search = Material(
      color: AppColors.green,
      shape: const CircleBorder(),
      elevation: 4,
      shadowColor: const Color(0xA6238869),
      child: InkWell(
        customBorder: const CircleBorder(),
        // On /mapa the results already follow the search state; from anywhere
        // else this lands on the results.
        onTap: () => context.go('/mapa'),
        child: const SizedBox(width: 52, height: 52, child: Icon(Icons.search, size: 22, color: Colors.white)),
      ),
    );

    return Container(
      height: 68,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: AppColors.fieldBorder),
        boxShadow: const [BoxShadow(color: Color(0x59112A22), blurRadius: 36, spreadRadius: -18, offset: Offset(0, 14))],
      ),
      child: Row(children: [
        const Expanded(flex: 115, child: DestinationField(style: DestinationStyle.segment)),
        divider(),
        segment(
          flex: 115,
          icon: Icons.calendar_month_outlined,
          iconSize: 24,
          iconColor: AppColors.neutral500,
          title: s.checkIn == null ? t('Adddates', 'Vyberte termín') : rangeLabel(s.checkIn, s.checkOut, t.lang),
          filled: s.checkIn != null,
          sub: t('CheckinCheckout', 'Príchod - Odchod'),
          onTap: (_) => showDatesModal(context, ref, monthWidth: 380),
          onClear: s.checkIn == null ? null : () => ref.read(searchProvider.notifier).setDates(null, null),
        ),
        divider(),
        segment(
          flex: 100,
          icon: Icons.person_add_alt,
          title: g.total == 0 ? t('Addguests', 'Pridať hostí') : '${g.total} ${t('guests', 'hostia').toLowerCase()}',
          filled: g.total > 0,
          sub: t('guests', 'Hostia'),
          onTap: (ctx) => showGuestsPanel(ctx, ref),
          onClear: g.total == 0 ? null : () => ref.read(searchProvider.notifier).setGuests(const Guests()),
          trailing: search,
        ),
      ]),
    );
  }
}

/// A popup-menu entry that is just a widget (the account menu has its own rows).
class _RawMenuEntry extends PopupMenuEntry<Never> {
  const _RawMenuEntry(this.child);
  final Widget child;
  @override
  double get height => 0;
  @override
  bool represents(Never? value) => false;
  @override
  State<_RawMenuEntry> createState() => _RawMenuEntryState();
}

class _RawMenuEntryState extends State<_RawMenuEntry> {
  @override
  Widget build(BuildContext context) => widget.child;
}

/// components/AccountMenu.js – name, profile, switch profile, logout.
class AccountMenu extends ConsumerStatefulWidget {
  const AccountMenu({super.key, required this.onClose, this.drawer = false});
  final VoidCallback onClose;

  /// The sidebar variant uses 16px text; the dropdown 14px.
  final bool drawer;
  @override
  ConsumerState<AccountMenu> createState() => _AccountMenuState();
}

class _AccountMenuState extends ConsumerState<AccountMenu> {
  bool _busy = false;

  Future<void> _switch(String mode) async {
    final t = ref.read(stringsProvider);
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).switchMode(mode, t.lang);
      if (!mounted) return;
      widget.onClose();
      context.go(mode == 'host' ? '/host' : '/guest');
    } catch (e) {
      if (mounted) {
        toast(
          context,
          e is Exception && errorText(e).isNotEmpty
              ? errorText(e)
              : t.pick('Prepnutie režimu zlyhalo.', 'Could not switch mode.'),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final auth = ref.watch(authProvider);
    if (!auth.loggedIn) return const SizedBox.shrink();
    final en = t.isEn;
    final size = widget.drawer ? 16.0 : 14.0;
    const gray700 = Color(0xFF374151);

    Widget item(IconData icon, String label, VoidCallback onTap) => InkWell(
          onTap: _busy ? null : onTap,
          borderRadius: BorderRadius.circular(6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Icon(icon, size: 16, color: gray700),
                const SizedBox(width: 8),
                Expanded(child: Text(label, style: AppText.inter(size: size, color: gray700, height: 1.5))),
              ]),
            ),
          ),
        );

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF3F4F6)))),
        child: Text(auth.name.isEmpty ? t('Account', 'Účet') : auth.name,
            style: AppText.inter(size: size, weight: FontWeight.w500, color: const Color(0xFF111827), height: 1.5)),
      ),
      const SizedBox(height: 8),
      item(Icons.person_outline, auth.isHost ? (en ? 'Host profile' : 'Profil hostiteľa') : t('profile', 'Profil'), () {
        widget.onClose();
        context.go(auth.isHost ? '/host' : '/guest');
      }),
      item(
        Icons.repeat_rounded,
        _busy
            ? (en ? 'Switching…' : 'Prepínam…')
            : auth.isHost
                ? (en ? 'Switch to Travel profile' : 'Prepnúť na profil cestovateľa')
                : (en ? 'Switch to Host profile' : 'Prepnúť na profil hostiteľa'),
        () => _switch(auth.isHost ? 'guest' : 'host'),
      ),
      item(Icons.logout, t('logout', 'Odhlásiť sa'), () async {
        widget.onClose();
        await ref.read(authProvider.notifier).logout();
        if (context.mounted) context.go('/');
      }),
      const SizedBox(height: 8),
    ]);
  }
}

/// Shared/MenuBar.js + Shared/NavMobile.js – the 288px sidebar behind the burger.
class StayHubDrawer extends ConsumerStatefulWidget {
  const StayHubDrawer({super.key});
  @override
  ConsumerState<StayHubDrawer> createState() => _StayHubDrawerState();
}

class _StayHubDrawerState extends ConsumerState<StayHubDrawer> {

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final auth = ref.watch(authProvider);
    final en = t.isEn;
    void close() => Navigator.of(context).pop();

    Widget item(Widget leading, String label, VoidCallback onTap, {Widget? trailing}) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppColors.neutral100,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                leading,
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label, style: AppText.inter(size: 16, weight: FontWeight.w500, color: AppColors.neutral900, height: 1.5)),
                ),
                if (trailing != null) trailing,
              ]),
            ),
          ),
        );
    const divider = Divider(height: 2, thickness: 2, color: AppColors.neutral100);

    Future<void> addAccommodation() async {
      if (!auth.loggedIn) {
        close();
        context.push('/login');
        return;
      }
      if (auth.isHost) {
        close();
        context.go('/host/listings/new');
        return;
      }
      // A guest must switch to their host account first (menu item above).
      // Toast before closing so the drawer's context is still live.
      toast(context, en ? 'Switch to host to add an accommodation.' : 'Prepnite sa na hostiteľa a pridajte ubytovanie.');
      close();
    }

    return Drawer(
      backgroundColor: Colors.white,
      width: 288,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
          // Logo, blurb and close button (mt-24 py-8 px-7).
          Stack(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 96 + 32, 28, 32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                GestureDetector(
                  onTap: () {
                    close();
                    context.go('/');
                  },
                  child: const StayHubLogo(height: 24),
                ),
                const SizedBox(height: 20),
                Text(
                  en
                      ? 'Discover the best accommodations and book your next stay easily.'
                      : 'Objavte najlepšie ubytovania a rezervujte si ďalší pobyt jednoducho.',
                  style: AppText.inter(size: 14, color: AppColors.neutral600, height: 24 / 14),
                ),
              ]),
            ),
            Positioned(
              top: 8 + 96,
              right: 8,
              child: IconButton(
                onPressed: close,
                tooltip: en ? 'Close' : 'Zavrieť',
                icon: const Icon(Icons.close, size: 20, color: AppColors.neutral700),
              ),
            ),
          ]),
          divider,
          if (auth.loggedIn) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
              child: AccountMenu(onClose: close, drawer: true),
            ),
            divider,
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (!auth.loggedIn) ...[
                item(const Icon(Icons.person_outline, size: 20, color: AppColors.neutral900),
                    en ? 'Login / Registration' : 'Prihlásiť sa / Registrácia', () {
                  close();
                  context.push('/login');
                }),
                const SizedBox(height: 4),
              ],
              item(const Icon(Icons.add, size: 20, color: AppColors.neutral900), en ? 'Add Accommodation' : 'Pridať ubytovanie',
                  addAccommodation),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// components/Footer/Footer.js
class StayHubFooter extends ConsumerWidget {
  const StayHubFooter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final auth = ref.watch(authProvider);
    final year = DateTime.now().year;

    Widget link(String text, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(text, style: AppText.inter(size: context.md ? 16 : 14, color: Colors.white.withValues(alpha: 0.7))),
          ),
        );
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(text.toUpperCase(),
              style: AppText.inter(size: 14, weight: FontWeight.w700, color: Colors.white, letterSpacing: 0.7)),
        );

    void rent() {
      if (!auth.loggedIn) {
        toast(context, t('Pleaseloginasahosttolistyourproperty', 'Prihláste sa prosím ako hostiteľ.'), error: true);
        context.push('/login');
      } else if (auth.isHost) {
        context.go('/host');
      } else {
        toast(context, t('OnlyhostscanlistpropertiesPleaseloginasahost', 'Iba hostitelia môžu pridávať ubytovania.'), error: true);
      }
    }

    final md = context.md, lg = context.lg, sm = context.sm;
    final small = Colors.white.withValues(alpha: 0.6);

    final brand = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('UK Stay Hub', style: AppText.fraunces(size: md ? 36 : 30, color: Colors.white, letterSpacing: -0.5)),
      const SizedBox(height: 12),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 384),
        child: Text(
          t('Footer_Description',
              'Nájdite a rezervujte si to najlepšie unikátne ubytovanie priamo cez UK Stay Hub. Rýchlo, bezpečne a bez skrytých poplatkov.'),
          style: AppText.inter(size: md ? 16 : 14, color: Colors.white.withValues(alpha: 0.7), height: 1.625),
        ),
      ),
      const SizedBox(height: 12),
      Text('UK Stay Hub Ltd',
          style: AppText.inter(size: md ? 14 : 12, weight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.8), height: 1.625)),
      Text('Registered in England and Wales\nukstayhub.co.uk · ukstayhub.com',
          style: AppText.inter(size: md ? 14 : 12, color: small, height: 1.625)),
    ]);

    Widget col(String title, List<Widget> links) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          heading(title),
          ...links,
        ]);

    final guests = col(t('Footer_ForGuests', 'Pre hostí'), [
      link(t('HowItWorks_Title', 'Ako to funguje'), () => context.go('/')),
      link(t('FAQ_Title', 'FAQ'), () => context.push('/caste-otazky')),
      link(t('Footer_BookingPolicy', 'Pravidlá rezervácie'), () => context.push('/obchodne-podmienky')),
      link(t('Footer_Safety', 'Bezpečnosť'), () => context.push('/ochrana-osobnych-udajov')),
    ]);
    final hosts = col(t('Footer_ForHosts', 'Pre hostiteľov'), [
      link(t('Footer_ListYourProperty', 'Pridať ubytovanie'), rent),
      link(t('Footer_HostSupport', 'Podpora pre hostiteľov'), () => context.push('/prirucka-hostitela')),
    ]);
    final aboutLinks = [
      link(t('AboutUs', 'O nás'), () => context.push('/o-nas')),
      link(t('Blog', 'Blog'), () => context.push('/blog')),
      link(t('Contact', 'Kontakt'), () => context.push('/kontakt')),
    ];
    // About sits in a third column on lg, below the other two (2 per row) otherwise.
    final about = lg
        ? col(t('Footer_AboutPutko', 'O UK Stay Hub'), aboutLinks)
        : col(t('Footer_AboutPutko', 'O UK Stay Hub'), [
            Wrap(spacing: 24, children: aboutLinks),
          ]);

    final nav = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: guests),
        const SizedBox(width: 24),
        Expanded(child: hosts),
        if (lg) ...[const SizedBox(width: 24), Expanded(child: about)],
      ]),
      if (!lg) ...[const SizedBox(height: 32), about],
    ]);

    final copyright = Text('© $year UK Stay Hub Ltd ${t('AllRightsReserved', 'Všetky práva vyhradené.')}',
        textAlign: TextAlign.center, style: AppText.inter(size: 14, color: small));
    final legal = Wrap(alignment: WrapAlignment.center, spacing: sm ? 24 : 16, children: [
      link(t('PrivacyPolicy', 'Ochrana osobných údajov'), () => context.push('/ochrana-osobnych-udajov')),
      link(t('TermCondition', 'Obchodné podmienky'), () => context.push('/obchodne-podmienky')),
    ]);

    return Container(
      width: double.infinity,
      color: AppColors.forest,
      // pt-8 pb-28 on phones (room for the sticky search button), md:py-10, lg:py-12.
      padding: EdgeInsets.fromLTRB(16, lg ? 48 : (md ? 40 : 32), 16, lg ? 48 : (md ? 40 : 112)),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1248),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (md)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 8, child: brand),
                SizedBox(width: lg ? 64 : 40),
                Expanded(flex: 15, child: nav),
              ])
            else ...[
              brand,
              const SizedBox(height: 32),
              nav,
            ],
            SizedBox(height: md ? 40 : 32),
            if (sm)
              Row(children: [Expanded(child: Align(alignment: Alignment.centerLeft, child: copyright)), const SizedBox(width: 24), legal])
            else ...[
              Center(child: copyright),
              const SizedBox(height: 16),
              Center(child: legal),
            ],
          ]),
        ),
      ),
    );
  }
}
