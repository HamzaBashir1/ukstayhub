import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../core/json.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/repo.dart';
import '../state/providers.dart';
import '../state/search.dart';

/// The search pickers exactly as ukstayhub.co.uk opens them:
/// * location – typed into the field, suggestions drop down right under it
///   (components/DestinationPicker.js);
/// * dates – a centred two-month modal on wide screens, a full-screen
///   calendar otherwise (HeroComponent/StayDatesRangeInput.js, MobileDatesInput.js);
/// * guests – a centred "Hostia" modal (HeroComponent/GuestsInput.js), a panel
///   under the field in the /mapa header (listing-stay-map/component/GuestsInput.js),
///   or counters that open inside the phone field (MobileGuestsInput1.js).

const _accent = Color(0xFF2C8360);
const _range = Color(0xFFD1FAE5); // emerald-100
const _scrim = Color(0x33112A22); // bg-[#112A22]/20

// ───────────────────────────── Suggestions ─────────────────────────────

class DestSuggestion {
  const DestSuggestion(this.type, this.label, {this.count = 0, this.cities = const [], this.regionId});
  final String type; // region | city | name
  final String label;
  final int count;
  final List<String> cities;
  final String? regionId;

  Destination toDestination() => switch (type) {
        'region' => Destination.region(label, cities, regionId ?? ''),
        'name' => Destination.name(label),
        _ => Destination.city(label),
      };
}

/// searchNormalization.mergeDestinationSuggestions: with no text the six
/// biggest cities/regions; otherwise up to eight best matches, stays last.
List<DestSuggestion> destinationSuggestions(
  String query,
  List<Json> regions,
  List<Json> destinations,
  List<String> stays,
) {
  final counts = <String, int>{};
  final cities = <DestSuggestion>[];
  for (final d in destinations) {
    final name = asString(d['nameSk']);
    final count = asInt(d['count']);
    if (name.isEmpty || count <= 0) continue;
    counts[searchKey(name)] = count;
    cities.add(DestSuggestion('city', name, count: count));
  }

  final regs = <DestSuggestion>[];
  for (final r in regions) {
    final rc = asStringList(r['cities']);
    final total = rc.map(searchKey).toSet().fold<int>(0, (a, k) => a + (counts[k] ?? 0));
    if (total > 0) regs.add(DestSuggestion('region', asString(r['nameSk']), count: total, cities: rc, regionId: asString(r['id'])));
  }
  final regionNames = regs.map((e) => searchKey(e.label)).toSet();
  final distinct = cities.where((c) => !regionNames.contains(searchKey(c.label))).toList();

  int byCount(DestSuggestion a, DestSuggestion b) => b.count != a.count ? b.count.compareTo(a.count) : a.label.compareTo(b.label);

  final key = searchKey(query);
  if (key.isEmpty) return ([...distinct, ...regs]..sort(byCount)).take(6).toList();

  int score(DestSuggestion s) {
    final title = searchKey(s.label);
    if (title == key) return 0;
    if (title.startsWith(key)) return 1;
    if (title.split(' ').any((w) => w.startsWith(key))) return 2;
    if (title.contains(key)) return 3;
    if (key.length >= 5 && (title.length - key.length).abs() <= 1) {
      var i = 0, j = 0, edits = 0;
      while (i < title.length && j < key.length) {
        if (title[i] == key[j]) {
          i++;
          j++;
        } else {
          edits++;
          if (edits > 1) break;
          if (title.length >= key.length) i++;
          if (key.length >= title.length) j++;
        }
      }
      if (edits + (title.length - i) + (key.length - j) <= 1) return 5;
    }
    return 1 << 30;
  }

  final seen = <String>{};
  final ranked = <(DestSuggestion, int)>[];
  for (final s in [...distinct, ...regs, for (final n in stays) DestSuggestion('name', n)]) {
    if (!seen.add('${s.type}:${searchKey(s.label)}')) continue;
    ranked.add((s, score(s)));
  }
  final direct = ranked.where((e) => e.$2 < 5).toList();
  final pool = direct.isNotEmpty ? direct : ranked.where((e) => e.$2 == 5).toList();
  pool.sort((a, b) {
    if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
    final at = a.$1.type == 'name' ? 1 : 0, bt = b.$1.type == 'name' ? 1 : 0;
    if (at != bt) return at.compareTo(bt);
    return byCount(a.$1, b.$1);
  });
  return pool.take(8).map((e) => e.$1).toList();
}

// ───────────────────────────── Location field ─────────────────────────────

enum DestinationStyle {
  /// Home md+ grid tile (68px, F7FAF8 fill).
  tile,

  /// Phone form row (min 70px).
  mobile,

  /// A segment of the /mapa header bar (no own fill).
  segment,

  /// The home header's compact pill (no icon or label).
  compact,
}

/// components/DestinationPicker.js – the field is the text input; the list
/// opens 8px under it, as wide as the field (at least 280px).
class DestinationField extends ConsumerStatefulWidget {
  const DestinationField({super.key, this.style = DestinationStyle.tile, this.onSubmitted});
  final DestinationStyle style;

  /// Enter pressed (the compact header bar searches on Enter).
  final VoidCallback? onSubmitted;

  @override
  ConsumerState<DestinationField> createState() => _DestinationFieldState();
}

class _DestinationFieldState extends ConsumerState<DestinationField> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _group = Object();
  Timer? _debounce;
  CancelToken? _cancel;
  List<String> _stays = const [];
  // Stay-name results per query (DestinationPicker.js resultsCache), so typing
  // back over earlier letters shows them again without waiting for the API.
  final Map<String, List<String>> _stayCache = {};
  final _fieldKey = GlobalKey();
  int _active = -1;
  double _width = 280;

  @override
  void initState() {
    super.initState();
    _ctrl.text = ref.read(searchProvider).destination?.label ?? '';
    _focus.addListener(() {
      if (_focus.hasFocus) {
        _portal.show();
        _loadStays(_ctrl.text);
      } else {
        _portal.hide();
        // Typed text that was never picked falls back to the chosen place.
        _ctrl.text = ref.read(searchProvider).destination?.label ?? '';
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _cancel?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _loadStays(String text) {
    _debounce?.cancel();
    final q = text.trim();
    // One letter matches nearly every stay name, so only cities/regions then.
    if (q.length < 2) {
      setState(() => _stays = const []);
      return;
    }
    final cached = _stayCache[q.toLowerCase()];
    if (cached != null) {
      setState(() => _stays = cached);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 90), () async {
      _cancel?.cancel();
      final token = CancelToken();
      _cancel = token;
      try {
        final r = await publicRepo.nameSuggestions(q, cancel: token);
        if (!mounted || token.isCancelled) return;
        final names = r.map((e) => asString(e['name'] ?? e['accommodationName'])).where((e) => e.isNotEmpty).toList();
        _stayCache[q.toLowerCase()] = names;
        // Ignore an answer for text the user has already typed past.
        if (_ctrl.text.trim() != q) return;
        setState(() => _stays = names);
      } catch (_) {
        // Suggestions are optional; cities and regions still show.
      }
    });
  }

  List<DestSuggestion> _items() => destinationSuggestions(
        _ctrl.text,
        ref.watch(tourismRegionsProvider).valueOrNull ?? const [],
        ref.watch(destinationsProvider).valueOrNull ?? const [],
        _stays,
      );

  void _choose(DestSuggestion s) {
    final t = ref.read(stringsProvider);
    var d = s.toDestination();
    if (s.type == 'region' && t.isEn) {
      final r = (ref.read(tourismRegionsProvider).valueOrNull ?? const <Json>[]).where((e) => asString(e['id']) == s.regionId).firstOrNull;
      if (r != null) d = Destination.region(asString(r['nameEn']), s.cities, s.regionId ?? '');
    }
    ref.read(searchProvider.notifier).setDestination(d);
    _ctrl.text = d.label;
    _focus.unfocus();
  }

  void _clear() {
    _ctrl.clear();
    _stays = const [];
    ref.read(searchProvider.notifier).setDestination(null);
    setState(() {});
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final n = _items().length;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown && n > 0) {
      setState(() => _active = (_active + 1) % n);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp && n > 0) {
      setState(() => _active = (_active - 1 + n) % n);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _focus.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _submit(String v) {
    final items = _items();
    if (_active >= 0 && _active < items.length) {
      _choose(items[_active]);
    } else if (items.isNotEmpty && v.trim().isNotEmpty) {
      _choose(items.first);
    } else if (v.trim().isNotEmpty) {
      _choose(DestSuggestion('city', v.trim()));
    }
    widget.onSubmitted?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    ref.listen<Destination?>(searchProvider.select((s) => s.destination), (_, d) {
      if (!_focus.hasFocus) _ctrl.text = d?.label ?? '';
    });
    // Rebuild (and re-measure the list) when the keyboard opens or closes.
    MediaQuery.viewInsetsOf(context);
    final style = widget.style;
    final focused = _focus.hasFocus;
    final hasText = _ctrl.text.isNotEmpty;

    final input = TextField(
      controller: _ctrl,
      focusNode: _focus,
      onChanged: (v) {
        setState(() => _active = -1);
        _loadStays(v);
      },
      onSubmitted: _submit,
      // The field's own tap-outside would unfocus on pointer-down over the
      // suggestion list and close it before the tap lands; the TapRegion
      // group below (field + list) handles taps outside instead.
      onTapOutside: (_) {},
      textInputAction: TextInputAction.search,
      style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.forestDark),
      cursorColor: AppColors.green,
      // A bare input: the app theme's filled/outlined field style must not show.
      decoration: InputDecoration(
        isCollapsed: true,
        filled: false,
        contentPadding: EdgeInsets.zero,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        hintText: t('Location', 'Lokalita'),
        hintStyle: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.neutral400),
      ),
    );

    final clear = hasText
        ? InkWell(
            onTap: _clear,
            customBorder: const CircleBorder(),
            child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.cancel_outlined, size: 16, color: AppColors.neutral500)),
          )
        : null;

    final Widget content;
    if (style == DestinationStyle.compact) {
      content = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [Expanded(child: input), if (clear != null) clear]),
      );
    } else {
      content = Padding(
        padding: style == DestinationStyle.mobile
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 14)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          const Icon(Icons.location_on_outlined, size: 20, color: AppColors.green),
          const SizedBox(width: 12),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('Whereareyougoing', 'Kam sa chystáte?').toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.inter(size: 11, weight: FontWeight.w700, color: AppColors.mutedGreen, letterSpacing: 0.55)),
              const SizedBox(height: 2),
              input,
            ]),
          ),
          if (clear != null) clear,
        ]),
      );
    }

    final Widget field = switch (style) {
      DestinationStyle.tile => AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 68,
          decoration: BoxDecoration(
            color: focused ? Colors.white : AppColors.fieldBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: focused ? AppColors.green : AppColors.fieldBorder),
            boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
          ),
          alignment: Alignment.center,
          child: content,
        ),
      DestinationStyle.mobile => AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          constraints: const BoxConstraints(minHeight: 70),
          decoration: BoxDecoration(
            color: focused ? Colors.white : AppColors.fieldBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: focused ? AppColors.greenFocus : AppColors.fieldBorder),
          ),
          alignment: Alignment.center,
          child: content,
        ),
      _ => content,
    };

    return TapRegion(
      groupId: _group,
      onTapOutside: (_) => _focus.unfocus(),
      child: Focus(
        onKeyEvent: _onKey,
        skipTraversal: true,
        child: LayoutBuilder(builder: (context, c) {
          _width = c.maxWidth.isFinite ? c.maxWidth : 280;
          return CompositedTransformTarget(
            link: _link,
            child: OverlayPortal(
              controller: _portal,
              overlayChildBuilder: (_) => _dropdown(t),
              child: GestureDetector(key: _fieldKey, onTap: () => _focus.requestFocus(), behavior: HitTestBehavior.opaque, child: field),
            ),
          );
        }),
      ),
    );
  }

  Widget _dropdown(Strings t) {
    final items = _items();
    final loading = ref.watch(destinationsProvider).isLoading || ref.watch(tourismRegionsProvider).isLoading;
    final error = ref.watch(destinationsProvider).hasError;
    final en = t.isEn;
    final q = _ctrl.text.trim();
    // Typed text with no match closes the list (Airbnb style), no dead end.
    if (!loading && !error && items.isEmpty && q.isNotEmpty) return const SizedBox.shrink();

    Widget note(String s) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text(s, style: AppText.inter(size: 14, color: AppColors.neutral500)),
        );

    final List<Widget> rows;
    if (loading && items.isEmpty) {
      rows = [note(en ? 'Loading destinations…' : 'Načítavam destinácie…')];
    } else if (error && items.isEmpty) {
      rows = [note(en ? 'Destinations are unavailable. Please try again.' : 'Destinácie nie sú dostupné. Skúste to znova.')];
    } else if (items.isEmpty) {
      rows = [note(en ? 'No stays found. Try another name or city.' : 'Nenašli sa ponuky. Skúste iný názov alebo mesto.')];
    } else {
      rows = [
        if (q.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text((en ? 'Popular destinations with stays' : 'Obľúbené destinácie s ponukami').toUpperCase(),
                style: AppText.inter(size: 12, weight: FontWeight.w600, color: AppColors.neutral500, letterSpacing: 0.3)),
          ),
        for (var i = 0; i < items.length; i++)
          Material(
            color: i == _active ? AppColors.neutral100 : Colors.white,
            child: InkWell(
              onTap: () => _choose(items[i]),
              hoverColor: AppColors.neutral50,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(children: [
                  Icon(
                    switch (items[i].type) {
                      'name' => Icons.apartment_outlined,
                      'region' => Icons.share_location_outlined,
                      _ => Icons.location_on_outlined,
                    },
                    size: 18,
                    color: AppColors.green,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(items[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.inter(size: 14, weight: FontWeight.w500, color: AppColors.neutral900)),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    switch (items[i].type) {
                      'region' => en ? 'Region' : 'Región',
                      'name' => en ? 'Stay' : 'Ubytovanie',
                      _ => en ? 'City' : 'Mesto',
                    },
                    style: AppText.inter(size: 12, color: AppColors.neutral500),
                  ),
                ]),
              ),
            ),
          ),
      ];
    }

    // Keep the list above the phone keyboard: at most 320px (max-h-80), less
    // when the keyboard leaves less room under the field.
    var maxHeight = 320.0;
    final box = _fieldKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      final mq = MediaQueryData.fromView(View.of(context));
      final top = box.localToGlobal(Offset(0, box.size.height)).dy + 8;
      maxHeight = (mq.size.height - mq.viewInsets.bottom - top - 12).clamp(120.0, 320.0);
    }

    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft,
        offset: const Offset(0, 8),
        child: TapRegion(
          groupId: _group,
          child: Container(
            width: math.max(_width, 280),
            constraints: BoxConstraints(maxHeight: maxHeight),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.neutral100),
              boxShadow: const [
                BoxShadow(color: Color(0x1A000000), blurRadius: 25, spreadRadius: -5, offset: Offset(0, 20)),
                BoxShadow(color: Color(0x0A000000), blurRadius: 10, spreadRadius: -6, offset: Offset(0, 8)),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: Colors.white,
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 8), children: rows),
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── Shared bits ─────────────────────────────

/// Centred modal over a blurred, tinted page (fixed inset-0 … backdrop-blur-[2px]).
Future<void> _showCentered(BuildContext context, {required Widget child, EdgeInsets padding = const EdgeInsets.all(24)}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (ctx, _, __) => Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 2, sigmaY: 2), child: const ColoredBox(color: _scrim)),
        ),
      ),
      SafeArea(child: Padding(padding: padding, child: Center(child: child))),
    ]),
    transitionBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
  );
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap, this.size = 32, this.iconSize = 16, this.color = AppColors.neutral100, this.fg = AppColors.neutral700});
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final Color color;
  final Color fg;

  @override
  Widget build(BuildContext context) => Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: size, height: size, child: Icon(icon, size: iconSize, color: fg)),
        ),
      );
}

/// Shared/NcInputNumber.js – label + description, − value + in a 112px group.
class NcCounter extends StatelessWidget {
  const NcCounter({super.key, required this.label, required this.value, required this.onChanged, this.desc, this.min = 0, this.max = 100});
  final String label;
  final String? desc;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, bool enabled, int next) => Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Material(
            color: Colors.white,
            shape: const CircleBorder(side: BorderSide(color: AppColors.neutral400)),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? () => onChanged(next) : null,
              child: SizedBox(width: 32, height: 32, child: Icon(icon, size: 16, color: AppColors.neutral700)),
            ),
          ),
        );
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: AppText.inter(size: 16, weight: FontWeight.w500, color: AppColors.neutral800, height: 1.5)),
          if (desc != null) Text(desc!, style: AppText.inter(size: 12, color: AppColors.neutral500, height: 16 / 12)),
        ]),
      ),
      const SizedBox(width: 20),
      SizedBox(
        width: 112,
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          btn(Icons.remove, value > min, value - 1),
          Text('$value', style: AppText.inter(size: 16, color: AppColors.neutral900)),
          btn(Icons.add, value < max, value + 1),
        ]),
      ),
    ]);
  }
}

/// The three counters, writing straight to the search like the site does.
class GuestCounters extends ConsumerWidget {
  const GuestCounters({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final g = ref.watch(searchProvider.select((s) => s.guests));
    void set(Guests v) => ref.read(searchProvider.notifier).setGuests(v);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      NcCounter(
        label: t('Adults', 'Dospelí'),
        desc: t('Ages13orabove', 'Vek 13 a viac'),
        value: g.adults,
        min: 1,
        onChanged: (v) => set(g.copyWith(adults: v)),
      ),
      const SizedBox(height: 24),
      NcCounter(
        label: t('Children', 'Deti'),
        desc: t('Ages212', 'Vek 2–12'),
        value: g.children,
        onChanged: (v) => set(g.copyWith(children: v)),
      ),
      const SizedBox(height: 24),
      NcCounter(
        label: t('Infants', 'Dojčatá'),
        desc: t('Ages02', 'Vek 0–2'),
        value: g.infants,
        onChanged: (v) => set(g.copyWith(infants: v)),
      ),
    ]);
  }
}

/// The site keeps one adult by default; a picker opening on 0 starts there.
void _ensureAdult(WidgetRef ref) {
  final g = ref.read(searchProvider).guests;
  if (g.adults == 0) ref.read(searchProvider.notifier).setGuests(g.copyWith(adults: 1));
}

// ───────────────────────────── Guests pickers ─────────────────────────────

/// HeroComponent/GuestsInput.js – centred "Hostia" modal (home form, md+).
Future<void> showGuestsModal(BuildContext context, WidgetRef ref) {
  _ensureAdult(ref);
  final t = ref.read(stringsProvider);
  return _showCentered(
    context,
    child: Builder(
      builder: (ctx) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        elevation: 24,
        shadowColor: const Color(0x40000000),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 384),
          padding: EdgeInsets.symmetric(horizontal: context.sm ? 32 : 20, vertical: 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.only(bottom: 16),
              margin: const EdgeInsets.only(bottom: 20),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFE7EFEB)))),
              child: Row(children: [
                Expanded(child: Text(t('Guests', 'Hostia'), style: AppText.dmSans(size: 16, weight: FontWeight.w600, color: AppColors.forestDark))),
                _RoundIcon(
                  icon: Icons.close,
                  size: 36,
                  iconSize: 20,
                  color: const Color(0xFFF0F7F4),
                  fg: AppColors.mutedGreen,
                  onTap: () => Navigator.of(ctx).pop(),
                ),
              ]),
            ),
            const GuestCounters(),
          ]),
        ),
      ),
    ),
  );
}

/// listing-stay-map/component/GuestsInput.js – a panel 12px under the field,
/// right-aligned to it, at least 340px wide (max 384), no backdrop.
Future<void> showGuestsPanel(BuildContext anchor, WidgetRef ref) {
  _ensureAdult(ref);
  final box = anchor.findRenderObject() as RenderBox;
  final overlay = Navigator.of(anchor).overlay!.context.findRenderObject() as RenderBox;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final width = rect.width.clamp(340.0, 384.0);
  return showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'close',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (ctx, _, __) => Stack(children: [
      Positioned(
        top: rect.bottom + 12,
        right: overlay.size.width - rect.right,
        width: width,
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          elevation: 12,
          shadowColor: const Color(0x33000000),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: GuestCounters(),
          ),
        ),
      ),
    ]),
    transitionBuilder: (_, a, __, child) => FadeTransition(
      opacity: a,
      child: SlideTransition(position: Tween(begin: const Offset(0, -0.01), end: Offset.zero).animate(a), child: child),
    ),
  );
}

// ───────────────────────────── Dates pickers ─────────────────────────────

List<String> _weekdays(String lang) =>
    lang == 'en' ? const ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'] : const ['PO', 'UT', 'ST', 'ŠT', 'PI', 'SO', 'NE'];

/// renderMonth: weekday row, leading days of the previous month greyed out,
/// past days at 40%, start/end in #2C8360, the nights between in emerald-100.
class _Month extends StatelessWidget {
  const _Month({
    required this.month,
    required this.lang,
    required this.start,
    required this.end,
    required this.onDay,
    required this.cell,
    required this.gap,
    required this.titleStyle,
    required this.weekdayStyle,
    required this.dayFont,
    required this.titleGap,
  });
  final DateTime month;
  final String lang;
  final DateTime? start;
  final DateTime? end;
  final ValueChanged<DateTime> onDay;
  final double cell;
  final double gap;
  final TextStyle titleStyle;
  final TextStyle weekdayStyle;
  final double dayFont;
  final double titleGap;

  @override
  Widget build(BuildContext context) {
    final today = dateOnly(DateTime.now());
    final first = DateTime(month.year, month.month);
    final lead = (first.weekday + 6) % 7;
    final days = DateTime(month.year, month.month + 1, 0).day;
    final cells = <Widget>[
      for (final w in _weekdays(lang)) Center(child: Text(w, style: weekdayStyle)),
      for (var i = lead; i > 0; i--)
        Center(child: Text('${first.subtract(Duration(days: i)).day}', style: AppText.inter(size: dayFont, color: const Color(0xFFD1D5DB)))),
      for (var d = 1; d <= days; d++)
        Builder(builder: (_) {
          final day = DateTime(month.year, month.month, d);
          final past = day.isBefore(today);
          final isEdge = (start != null && day == start) || (end != null && day == end);
          final inRange = start != null && end != null && day.isAfter(start!) && day.isBefore(end!);
          return Center(
            child: Opacity(
              opacity: past ? 0.4 : 1,
              child: Material(
                color: isEdge ? _accent : (inRange ? _range : Colors.transparent),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  hoverColor: _accent.withValues(alpha: 0.85),
                  onTap: past ? null : () => onDay(day),
                  child: SizedBox(
                    width: cell,
                    height: cell,
                    child: Center(
                      child: Text('$d',
                          style: AppText.inter(size: dayFont, weight: FontWeight.w500, color: isEdge ? Colors.white : AppColors.neutral900)),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
    ];
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 7) {
      if (rows.isNotEmpty) rows.add(SizedBox(height: gap));
      rows.add(SizedBox(
        height: cell,
        child: Row(children: [
          for (var j = 0; j < 7; j++) ...[
            if (j > 0) SizedBox(width: gap),
            Expanded(child: i + j < cells.length ? cells[i + j] : const SizedBox()),
          ],
        ]),
      ));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(monthTitle(month, lang), textAlign: TextAlign.center, style: titleStyle),
      SizedBox(height: titleGap),
      ...rows,
    ]);
  }
}

/// Range picking as the site does it: first tap starts, a later day ends,
/// an earlier day moves the start, a tap after a full range starts again.
(DateTime?, DateTime?) _pick(DateTime? s, DateTime? e, DateTime day) {
  if (s == null || e != null) return (day, null);
  if (day.isBefore(s)) return (day, null);
  if (day == s) return (s, null);
  return (s, day);
}

/// HeroComponent/StayDatesRangeInput.js (xl+) and the /mapa header: a centred
/// modal, two months side by side, every tap saved straight away.
/// [monthWidth] is 340 on the home page and 380 in the /mapa header.
Future<void> showDatesModal(BuildContext context, WidgetRef ref, {double monthWidth = 340}) {
  final t = ref.read(stringsProvider);
  final s = ref.read(searchProvider);
  var month = DateTime((s.checkIn ?? DateTime.now()).year, (s.checkIn ?? DateTime.now()).month);
  return _showCentered(
    context,
    child: StatefulBuilder(
      builder: (ctx, setLocal) => Consumer(builder: (ctx, ref, _) {
        final st = ref.watch(searchProvider);
        void onDay(DateTime d) {
          final (a, b) = _pick(st.checkIn, st.checkOut, d);
          ref.read(searchProvider.notifier).setDates(a, b);
        }

        final now = DateTime.now();
        final canBack = month.isAfter(DateTime(now.year, now.month));
        Widget m(DateTime mm) => SizedBox(
              width: monthWidth,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _Month(
                  month: mm,
                  lang: t.lang,
                  start: st.checkIn,
                  end: st.checkOut,
                  onDay: onDay,
                  cell: 40,
                  gap: 8,
                  dayFont: 14,
                  titleGap: 16,
                  titleStyle: AppText.inter(size: 18, weight: FontWeight.w600, color: AppColors.neutral900),
                  weekdayStyle: AppText.inter(size: 12, weight: FontWeight.w500, color: const Color(0xFF4B5563)),
                ),
              ),
            );
        Widget nav(IconData icon, VoidCallback? onTap) => Opacity(
              opacity: onTap == null ? 0.3 : 1,
              child: _RoundIcon(icon: icon, onTap: onTap, color: Colors.transparent, fg: AppColors.neutral900),
            );

        return Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          elevation: 24,
          shadowColor: const Color(0x40000000),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Stack(children: [
              Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                m(month),
                const SizedBox(width: 32),
                m(DateTime(month.year, month.month + 1)),
              ]),
              Positioned(left: 8, top: 8, child: nav(Icons.chevron_left, canBack ? () => setLocal(() => month = DateTime(month.year, month.month - 1)) : null)),
              Positioned(right: 40, top: 8, child: nav(Icons.chevron_right, () => setLocal(() => month = DateTime(month.year, month.month + 1)))),
              Positioned(
                right: -4,
                top: -4,
                child: _RoundIcon(icon: Icons.close, size: 24, iconSize: 12, fg: AppColors.neutral600, onTap: () => Navigator.of(ctx).pop()),
              ),
            ]),
          ),
        );
      }),
    ),
  );
}

/// The full-screen calendar: HeroComponent/StayDatesRangeInput.js below xl,
/// or MobileDatesInput.js in the phone form ([phone] – smaller cells and
/// buttons). Nothing is saved until "Uložiť".
Future<void> showDatesFullScreen(BuildContext context, WidgetRef ref, {bool phone = false}) {
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (_, __, ___) => _FullScreenDates(phone: phone),
    transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
  ));
}

class _FullScreenDates extends ConsumerStatefulWidget {
  const _FullScreenDates({required this.phone});
  final bool phone;
  @override
  ConsumerState<_FullScreenDates> createState() => _FullScreenDatesState();
}

class _FullScreenDatesState extends ConsumerState<_FullScreenDates> {
  late DateTime? _a = ref.read(searchProvider).checkIn;
  late DateTime? _b = ref.read(searchProvider).checkOut;
  late DateTime _month = DateTime((_a ?? DateTime.now()).year, (_a ?? DateTime.now()).month);

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final phone = widget.phone;
    final md = context.md;
    final cell = phone ? 32.0 : (md ? 40.0 : 32.0);

    Widget month(DateTime m) {
      final cal = _Month(
        month: m,
        lang: t.lang,
        start: _a,
        end: _b,
        onDay: (d) => setState(() {
          final (a, b) = _pick(_a, _b, d);
          _a = a;
          _b = b;
        }),
        cell: cell,
        gap: phone ? 4 : (md ? 8 : 4),
        dayFont: phone ? 12 : (md ? 14 : 12),
        titleGap: phone ? 12 : 16,
        titleStyle: phone
            ? AppText.inter(size: 16, weight: FontWeight.w600, color: AppColors.neutral800)
            : AppText.inter(size: 18, weight: FontWeight.w600, color: AppColors.neutral900),
        weekdayStyle: phone
            ? AppText.inter(size: 10, weight: FontWeight.w600, color: AppColors.neutral400)
            : AppText.inter(size: 12, weight: FontWeight.w500, color: const Color(0xFF4B5563)),
      );
      if (phone) return Padding(padding: const EdgeInsets.all(16), child: cal);
      return Center(
        child: SizedBox(width: md ? 380 : 340, child: Padding(padding: const EdgeInsets.all(16), child: cal)),
      );
    }

    final now = DateTime.now();
    final canBack = _month.isAfter(DateTime(now.year, now.month));
    final navRow = Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: phone ? 12 : 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Opacity(
          opacity: canBack ? 1 : 0.4,
          child: _RoundIcon(icon: Icons.chevron_left, onTap: canBack ? () => setState(() => _month = DateTime(_month.year, _month.month - 1)) : null),
        ),
        _RoundIcon(icon: Icons.chevron_right, onTap: () => setState(() => _month = DateTime(_month.year, _month.month + 1))),
      ]),
    );

    final btnPad = EdgeInsets.symmetric(vertical: phone ? 14 : 16);
    final btnText = phone
        ? AppText.inter(size: 14, weight: FontWeight.w600)
        : AppText.inter(size: 16, weight: FontWeight.w700);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.neutral100))),
            child: Row(children: [
              Expanded(
                child: Text(t('CheckinCheckout', 'Príchod - Odchod'),
                    style: AppText.inter(size: 16, weight: FontWeight.w700, color: phone ? AppColors.neutral900 : const Color(0xFF0F291E))),
              ),
              _RoundIcon(icon: Icons.close, onTap: () => Navigator.of(context).pop()),
            ]),
          ),
          if (phone) navRow,
          Expanded(
            child: ListView(
              padding: phone ? EdgeInsets.zero : const EdgeInsets.all(8),
              children: [
                if (!phone) navRow,
                month(_month),
                month(DateTime(_month.year, _month.month + 1)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_a != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _b != null ? '${shortDate(_a!, t.lang)} → ${shortDate(_b!, t.lang)}' : '${shortDate(_a!, t.lang)} — ${t('Adddates', 'Vyberte termín')}',
                    textAlign: TextAlign.center,
                    style: AppText.inter(size: 14, color: phone ? AppColors.neutral400 : AppColors.neutral500),
                  ),
                ),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.neutral700,
                      side: BorderSide(color: phone ? AppColors.neutral200 : AppColors.neutral300),
                      padding: btnPad,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(t('close', 'Zavrieť'), style: btnText.copyWith(color: AppColors.neutral700)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      ref.read(searchProvider.notifier).setDates(_a, _a == null ? null : _b);
                      Navigator.of(context).pop();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      padding: btnPad,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(t('save', 'Uložiť'), style: btnText.copyWith(color: Colors.white)),
                  ),
                ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
