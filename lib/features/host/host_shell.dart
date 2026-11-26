import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../state/auth.dart';
import '../../widgets/common.dart';
import 'editor_steps4.dart';
import '../../widgets/brand_logo_mark.dart';

const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;

// ───────────────────────────── Shared host data ─────────────────────────────
final hostDashboardProvider = FutureProvider.autoDispose<Json>((ref) => hostRepo.dashboard());
final hostListingsProvider = FutureProvider.autoDispose<List<Json>>((ref) => hostRepo.listings());
final hostOwnedProvider = FutureProvider.autoDispose<List<Json>>((ref) => hostRepo.ownedAccommodations());
final hostReservationsProvider = FutureProvider.autoDispose<List<Json>>((ref) => hostRepo.reservations());
final hostConversationsProvider = FutureProvider.autoDispose<List<Json>>((ref) => hostRepo.conversations());

/// The five primary entries of host/[[...section]]/page.js (NAV_ITEMS).
class HostTab {
  const HostTab(this.id, this.path, this.icon, this.sk, this.en);
  final String id;
  final String path;
  final IconData icon;
  final String sk;
  final String en;
}

const hostTabs = [
  HostTab('today', '/host', Icons.dashboard_outlined, 'Dnes', 'Today'),
  HostTab('listings', '/host/listings', Icons.home_outlined, 'Moje ubytovania', 'Listings'),
  HostTab('calendar', '/host/calendar', Icons.calendar_month_outlined, 'Kalendár', 'Calendar'),
  HostTab('reservations', '/host/reservations', Icons.assignment_outlined, 'Rezervácie', 'Reservations'),
  HostTab('messages', '/host/messages', Icons.chat_outlined, 'Správy', 'Messages'),
];

bool _isActive(String loc, String path) => path == '/host' ? loc == '/host' : loc.startsWith(path);

/// Web `lg` breakpoint: fixed 280px sidebar, no top/bottom bars.
const _lg = 1024.0;

/// Host workspace chrome. Phone/tablet (<1024): top bar, bottom nav and slide-out
/// menu. Wide (>=1024): fixed sidebar. Mirrors `HostWorkspaceShell`.
class HostShell extends ConsumerWidget {
  const HostShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  int get _index {
    for (var i = hostTabs.length - 1; i >= 0; i--) {
      if (_isActive(location, hostTabs[i].path)) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final dash = ref.watch(hostDashboardProvider).valueOrNull;
    final openRequests = asInt(pick(dash, 'requests.count'));
    final unread = asInt(pick(dash, 'messages.unreadMessages'));
    final payoutsBlocked = pick(dash, 'payouts.blocker') != null;
    final attention = hostAttention(ref.watch(hostListingsProvider).valueOrNull ?? const [], ref.watch(hostStripeAccountsProvider).valueOrNull);
    final idx = _index;
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= _lg;
    // The listing editor brings its own header and action bar on phones and tablets.
    final editorOpen = RegExp(r'^/host/listings/[^/]+$').hasMatch(location);
    final label = idx >= 0
        ? t.pick(hostTabs[idx].sk, hostTabs[idx].en)
        : location.startsWith('/host/profile')
            ? t.pick('Hostiteľský profil', 'Host profile')
            : location.startsWith('/host/payouts')
                ? t.pick('Účty a príjmy', 'Accounts & earnings')
                : location.startsWith('/host/account')
                    ? t.pick('Osobné údaje a heslo', 'Personal details & password')
                    : t.pick('Pracovisko hostiteľa', 'Host workspace');

    // main: px-0 pt-4 · sm:px-6 · lg:px-10 lg:pt-10
    final side = width >= 640 ? 24.0 : 0.0;
    final pad = wide ? const EdgeInsets.fromLTRB(40, 40, 40, 0) : EdgeInsets.fromLTRB(side, 16, side, 0);
    final content = Padding(padding: pad, child: child);

    if (wide) {
      return Scaffold(
        backgroundColor: AppColors.hostBg,
        body: Row(children: [
          Container(
            width: 280,
            decoration: const BoxDecoration(color: _forest, boxShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 50, offset: Offset(0, 25))]),
            child: _HostNavPanel(closable: false, location: location),
          ),
          Expanded(child: content),
        ]),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.hostBg,
      drawer: Drawer(
        backgroundColor: _forest,
        width: (width - 32).clamp(0, 340).toDouble(),
        shape: const RoundedRectangleBorder(),
        child: _HostNavPanel(closable: true, location: location),
      ),
      appBar: editorOpen ? null : PreferredSize(
        preferredSize: const Size.fromHeight(57),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.9),
            border: const Border(bottom: BorderSide(color: AppColors.neutral200)),
            boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(children: [
                Builder(
                  builder: (ctx) => InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Scaffold.of(ctx).openDrawer(),
                    child: const SizedBox(width: 44, height: 44, child: Icon(Icons.menu_rounded, size: 24, color: _forest)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(t.pick('HOSTITEĽ', 'HOST'), style: AppText.inter(size: 10, weight: FontWeight.w700, color: AppColors.neutral400, letterSpacing: 1.5)),
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
                  ]),
                ),
                InkWell(
                  onTap: () => context.go('/'),
                  child: const SizedBox(height: 44, child: Align(alignment: Alignment.centerRight, child: StayHubLogo(height: 24))),
                ),
              ]),
            ),
          ),
        ),
      ),
      body: editorOpen ? Padding(padding: EdgeInsets.fromLTRB(side, 0, side, 0), child: child) : content,
      bottomNavigationBar: editorOpen ? null : Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AppColors.neutral200)),
          boxShadow: [BoxShadow(color: Color(0x0D000000), blurRadius: 20, offset: Offset(0, -4))],
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 76,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(children: [
                for (var i = 0; i < hostTabs.length; i++)
                  Expanded(
                    child: _NavItem(
                      icon: hostTabs[i].icon,
                      label: t.pick(hostTabs[i].sk, hostTabs[i].en),
                      active: i == idx,
                      compact: width < 410,
                      badge: hostTabs[i].id == 'reservations' ? openRequests : (hostTabs[i].id == 'messages' ? unread : 0),
                      dot: hostTabs[i].id == 'listings' && attention.listings,
                      onTap: () => context.go(hostTabs[i].path),
                    ),
                  ),
                Expanded(
                  child: Builder(
                    builder: (ctx) => _NavItem(
                      icon: Icons.menu_rounded,
                      label: 'Menu',
                      active: false,
                      compact: width < 410,
                      dot: payoutsBlocked || attention.payouts,
                      onTap: () => Scaffold.of(ctx).openDrawer(),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.icon, required this.label, required this.active, required this.onTap, required this.compact, this.badge = 0, this.dot = false});
  final IconData icon;
  final String label;
  final bool active;
  final bool compact;
  final int badge;
  final bool dot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(
            height: 30,
            child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
              Icon(icon, size: 26, color: active ? _gold : AppColors.neutral400),
              if (badge > 0)
                Positioned(
                  right: -10,
                  top: -6,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: AppColors.amber, borderRadius: BorderRadius.circular(9)),
                    child: Text(badge > 9 ? '9+' : '$badge', style: AppText.inter(size: 10, weight: FontWeight.w700, color: Colors.white, height: 1)),
                  ),
                ),
              if (dot)
                Positioned(
                  right: -10,
                  top: -6,
                  child: Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFDC2626), width: 2),
                    ),
                    child: Text('!', style: AppText.inter(size: 11, weight: FontWeight.w800, color: const Color(0xFFDC2626), height: 1)),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 24,
            child: Text(
              label.toUpperCase(),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.clip,
              style: AppText.inter(
                size: compact ? 9 : 10,
                weight: active ? FontWeight.w700 : FontWeight.w600,
                color: active ? _forest : (label == 'Menu' ? AppColors.neutral500 : AppColors.neutral400),
                height: 11 / (compact ? 9 : 10),
                letterSpacing: compact ? -0.1 : 0,
              ),
            ),
          ),
        ]),
      );
}

/// Shared by the fixed sidebar and the slide-out drawer (`renderNavigation`).
class _HostNavPanel extends ConsumerWidget {
  const _HostNavPanel({required this.closable, required this.location});

  /// The current path, handed down by the shell. (Reading it with GoRouterState.of from a panel that is
  /// always mounted ties the panel to the route's inherited state, which is torn down on login.)
  final String location;
  final bool closable;

  // Port of selectPriorityListing: READY, then oldest DRAFT, then most recently updated.
  static Json? _priority(List<Json> all) {
    final list = all.where((l) => l['legacy'] != true).toList();
    if (list.isEmpty) return null;
    DateTime time(Json l, String k) => DateTime.tryParse(asString(l[k])) ?? DateTime.fromMillisecondsSinceEpoch(0);
    Json oldest(List<Json> xs) => xs.reduce((a, b) => time(b, 'createdAt').isBefore(time(a, 'createdAt')) ? b : a);
    final ready = list.where((l) => asString(l['status']) == 'READY').toList();
    if (ready.isNotEmpty) return oldest(ready);
    final drafts = list.where((l) => asString(l['status']) == 'DRAFT').toList();
    if (drafts.isNotEmpty) return oldest(drafts);
    list.sort((a, b) => time(b, 'updatedAt').compareTo(time(a, 'updatedAt')));
    return list.first;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final auth = ref.watch(authProvider);
    final dash = ref.watch(hostDashboardProvider).valueOrNull;
    final listingsAsync = ref.watch(hostListingsProvider);
    final loc = location;
    final openRequests = asInt(pick(dash, 'requests.count'));
    final unread = asInt(pick(dash, 'messages.unreadMessages'));
    final attention = hostAttention(listingsAsync.valueOrNull ?? const [], ref.watch(hostStripeAccountsProvider).valueOrNull);

    void go(String path) {
      if (closable) Scaffold.of(context).closeDrawer();
      context.go(path);
    }

    Future<void> addListing() async {
      try {
        final l = await hostRepo.createListing();
        ref.invalidate(hostListingsProvider);
        if (closable && context.mounted) Scaffold.of(context).closeDrawer();
        if (context.mounted) context.go('/host/listings/${asString(l['id'])}');
      } catch (e) {
        if (context.mounted) toast(context, errorText(e), error: true);
      }
    }

    Widget navButton({required IconData icon, required String label, required VoidCallback onTap, bool active = false, int badge = 0, bool dot = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Material(
            color: active ? _gold : Colors.transparent,
            elevation: active ? 3 : 0,
            shadowColor: const Color(0x33000000),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              child: Container(
                constraints: const BoxConstraints(minHeight: 44),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(children: [
                  Icon(icon, size: 20, color: active ? _forest : _gold),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(label, style: AppText.inter(size: 15, weight: active ? FontWeight.w700 : FontWeight.w600, color: active ? _forest : Colors.white70)),
                  ),
                  if (dot) Container(width: 10, height: 10, margin: const EdgeInsets.only(left: 8), decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle)),
                  if (badge > 0)
                    Container(
                      constraints: const BoxConstraints(minWidth: 22),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: active ? _forest : _gold, borderRadius: BorderRadius.circular(99)),
                      child: Text(badge > 9 ? '9+' : '$badge', style: AppText.inter(size: 11, weight: FontWeight.w700, color: active ? _gold : _forest, height: 1.3)),
                    ),
                ]),
              ),
            ),
          ),
        );

    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Text(text.toUpperCase(), style: AppText.inter(size: 11, weight: FontWeight.w700, color: Colors.white38, letterSpacing: 1.6)),
        );

    // "Next step" card (setupCopy)
    final target = _priority(listingsAsync.valueOrNull ?? const []);
    final dataName = asString(pick(target, 'data.name')).trim();
    final plainName = asString(target?['name']).trim();
    final targetName = dataName.isNotEmpty ? dataName : (plainName.isNotEmpty ? plainName : t.pick('Ponuka bez názvu', 'Unnamed listing'));
    final status = asString(target?['status']);
    final String setupTitle, setupAction;
    final VoidCallback setupTap;
    if (!listingsAsync.hasValue) {
      setupTitle = t.pick('Načítavajú sa ponuky…', 'Loading your listings…');
      setupAction = t.pick('Otvoriť ponuky', 'Open listings');
      setupTap = () => go('/host/listings');
    } else if (target == null) {
      setupTitle = t.pick('Pridajte prvé ubytovanie', 'Add your first listing');
      setupAction = t.pick('Začať nastavenie', 'Start setup');
      setupTap = addListing;
    } else if (status == 'READY') {
      setupTitle = t.pick('Zverejnite $targetName', 'Publish $targetName');
      setupAction = t.pick('Skontrolovať a zverejniť', 'Review and publish');
      setupTap = () => go('/host/listings/${asString(target['id'])}?review=1');
    } else if (status == 'DRAFT') {
      setupTitle = t.pick('Dokončite $targetName', 'Finish $targetName');
      setupAction = t.pick('Pokračovať v nastavení', 'Continue setup');
      setupTap = () => go('/host/listings/${asString(target['id'])}');
    } else {
      setupTitle = t.pick('Všetky ponuky sú zverejnené', 'All listings are live');
      setupAction = t.pick('Spravovať ponuky', 'Manage listings');
      setupTap = () => go('/host/listings');
    }
    final percent = target == null ? 0 : (status == 'LIVE' || status == 'READY' ? 100 : asInt(target['completionPercent']).clamp(0, 100));
    final nameSrc = auth.name.trim().isNotEmpty ? auth.name.trim() : auth.email.trim();
    final initial = nameSrc.isEmpty ? 'H' : nameSrc[0].toUpperCase();

    // Scrolls as a whole (header, entries, footer) so a short window can never overflow.
    return SafeArea(
      child: CustomScrollView(slivers: [
        SliverToBoxAdapter(child: Container(
          padding: const EdgeInsets.all(20),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white12))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              InkWell(
                onTap: () => go('/'),
                child: const SizedBox(
                  height: 44,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: StayHubLogo(height: 26, onDark: true),
                  ),
                ),
              ),
              if (closable)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Scaffold.of(context).closeDrawer(),
                  child: const SizedBox(width: 44, height: 44, child: Icon(Icons.close, size: 20, color: Colors.white)),
                ),
            ]),
            const SizedBox(height: 24),
            Row(children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: _gold, borderRadius: BorderRadius.circular(16)),
                child: Text(initial, style: AppText.inter(size: 20, weight: FontWeight.w700, color: _forest)),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(t.pick('Profil hostiteľa', 'Host profile'), style: AppText.inter(size: 15, weight: FontWeight.w700, color: Colors.white, height: 1.25))),
            ]),
          ]),
        )),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
          sliver: SliverList(delegate: SliverChildListDelegate([
            heading(t.pick('Hlavné', 'Main')),
            for (final tab in hostTabs)
              navButton(
                icon: tab.icon,
                label: t.pick(tab.sk, tab.en),
                active: _isActive(loc, tab.path),
                badge: tab.id == 'reservations' ? openRequests : (tab.id == 'messages' ? unread : 0),
                dot: tab.id == 'listings' && attention.listings,
                onTap: () => go(tab.path),
              ),
            navButton(icon: Icons.add, label: t.pick('Pridať nove ubytovanie', 'Add listing'), onTap: addListing),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white10)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.pick('ĎALŠÍ KROK', 'NEXT STEP'), style: AppText.inter(size: 10, weight: FontWeight.w700, color: _gold, letterSpacing: 1.5)),
                      const SizedBox(height: 4),
                      Text(setupTitle, style: AppText.inter(size: 14, weight: FontWeight.w700, color: Colors.white, height: 1.4)),
                    ]),
                  ),
                  const SizedBox(width: 12),
                  Text('$percent%', style: AppText.inter(size: 12, weight: FontWeight.w700, color: Colors.white70)),
                ]),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(value: percent / 100, minHeight: 6, color: _gold, backgroundColor: Colors.white24),
                ),
                const SizedBox(height: 12),
                Material(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: setupTap,
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(children: [
                        Expanded(child: Text(setupAction, style: AppText.inter(size: 12, weight: FontWeight.w700, color: Colors.white))),
                        const Icon(Icons.chevron_right, size: 15, color: Colors.white),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 24),
            heading(t.pick('Nastavenia hostiteľa', 'Host settings')),
            navButton(icon: Icons.person_outline, label: t.pick('Hostiteľský profil', 'Host profile'), active: _isActive(loc, '/host/profile'), onTap: () => go('/host/profile')),
            navButton(icon: Icons.account_balance_outlined, label: t.pick('Účty a príjmy', 'Accounts & earnings'), active: _isActive(loc, '/host/payouts'), dot: attention.payouts, onTap: () => go('/host/payouts')),
            navButton(icon: Icons.key_outlined, label: t.pick('Osobné údaje a heslo', 'Personal details & password'), active: _isActive(loc, '/host/account'), onTap: () => go('/host/account')),
            const SizedBox(height: 24),
            heading(t.pick('Pomoc', 'Help')),
            navButton(icon: Icons.menu_book_outlined, label: t.pick('Príručka', 'Host Guide'), onTap: () => go('/prirucka-hostitela')),
          ])),
        ),
        SliverFillRemaining(hasScrollBody: false, child: Align(alignment: Alignment.bottomCenter, child: Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(color: Color(0x1A000000), border: Border(top: BorderSide(color: Colors.white12))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  await ref.read(authProvider.notifier).switchMode('guest', t.lang);
                  if (context.mounted) context.go('/guest');
                } catch (e) {
                  if (context.mounted) toast(context, errorText(e), error: true);
                }
              },
              icon: const Icon(Icons.arrow_back, size: 18),
              label: Text(t.pick('Prepnúť na Cestovanie', 'Switch to Travel'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: Colors.white.withValues(alpha: 0.9))),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white.withValues(alpha: 0.9),
                side: const BorderSide(color: Colors.white24),
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => go('/'),
              icon: const Icon(Icons.undo, size: 16),
              label: Text(t.pick('Návrat na web', 'Return to Web'), style: AppText.inter(size: 13, weight: FontWeight.w700, color: Colors.white54)),
              style: TextButton.styleFrom(foregroundColor: Colors.white54, minimumSize: const Size.fromHeight(44)),
            ),
          ]),
        ))),
      ]),
    );
  }
}

/// White rounded card used throughout the workspace.
class HostCard extends StatelessWidget {
  const HostCard({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.onTap, this.border});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? border;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: border ?? AppColors.neutral200)),
            child: child,
          ),
        ),
      );
}

class HostPageTitle extends StatelessWidget {
  const HostPageTitle(this.title, {super.key, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.fraunces(size: 26, color: AppColors.hostForest)),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle!, style: AppText.inter(size: 14, color: AppColors.neutral500)),
              ],
            ]),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Stage/status chip used on reservations and listings.
Widget hostStatusChip(String status, Strings t) {
  final s = status.toLowerCase();
  final (sk, en, fg, bg) = switch (s) {
    'live' || 'published' => ('Zverejnené', 'Live', const Color(0xFF047857), const Color(0xFFECFDF5)),
    'request' || 'pending' || 'requested' => ('Žiadosť', 'Request', const Color(0xFFB45309), const Color(0xFFFFFBEB)),
    'upcoming' || 'approved' => ('Nadchádzajúca', 'Upcoming', const Color(0xFF1D4ED8), const Color(0xFFEFF6FF)),
    'active' => ('Prebieha', 'In progress', const Color(0xFF047857), const Color(0xFFECFDF5)),
    'completed' => ('Ukončená', 'Completed', AppColors.neutral600, AppColors.neutral100),
    'declined' => ('Zamietnutá', 'Declined', AppColors.red, const Color(0xFFFEF2F2)),
    'cancelled' => ('Zrušená', 'Cancelled', AppColors.red, const Color(0xFFFEF2F2)),
    'ready' => ('Pripravené', 'Ready', const Color(0xFF1D4ED8), const Color(0xFFEFF6FF)),
    _ => ('Koncept', 'Draft', AppColors.neutral600, AppColors.neutral100),
  };
  return Pill(t.pick(sk, en), fg: fg, bg: bg);
}
