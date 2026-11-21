import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/repo.dart';
import '../../widgets/common.dart';
import 'stay_map_layout.dart';

const _ink = Color(0xFF1A3A2E);
/// Central London (Trafalgar Square).
const _london = LatLng(51.5080, -0.1281);

/// /mapa map (ListingMap.js + SectionGridHasMap.js).
///
/// Same data as the website: pins come from `/accommodations/searching?…&mapOnly=true`
/// (the search filters without paging), the tapped stay's card from
/// `/accommodation/:id?fields=mapCard`. Pins are laid out like the web does — only
/// those in the viewport, price pills where there is room, dots where pills would
/// overlap — so the map stays light with hundreds of stays. OpenStreetMap tiles:
/// no API key ships in the app.
class StayMap extends ConsumerStatefulWidget {
  const StayMap({super.key, required this.query, this.resultListings = const []});

  /// The search filters (no page/limit), as for the result list.
  final Map<String, dynamic> query;

  /// Stays on the current results page: they get pill slots first and their card
  /// opens instantly without a request.
  final List<Listing> resultListings;

  @override
  ConsumerState<StayMap> createState() => _StayMapState();
}

class _StayMapState extends ConsumerState<StayMap> {
  final _map = MapController();
  List<Listing> _pins = const [];
  List<PlacedPin> _placed = const [];
  String? _selectedId;
  Listing? _selected; // card data; null while its mapCard request is in flight
  bool _loading = true;
  bool _failed = false;
  bool _ready = false;
  bool _fitted = false; // pins are held back until the first fit settles
  int _gen = 0;
  Timer? _layoutTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant StayMap old) {
    super.didUpdateWidget(old);
    if (old.query.toString() != widget.query.toString()) {
      _load();
    } else if (old.resultListings != widget.resultListings) {
      _scheduleLayout();
    }
  }

  @override
  void dispose() {
    _layoutTimer?.cancel();
    _map.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final pins = await publicRepo.mapPins(Map.of(widget.query)..remove('fields'));
      if (!mounted || gen != _gen) return;
      setState(() {
        _pins = pins;
        _selectedId = null;
        _selected = null;
        _placed = const [];
        _fitted = false;
      });
      _fit();
    } catch (_) {
      if (mounted && gen == _gen) setState(() => _failed = true);
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  void _fit() {
    if (!_ready || _pins.isEmpty) return;
    final points = [for (final p in _pins) LatLng(p.lat!, p.lng!)];
    if (points.length == 1) {
      _map.move(points.first, 12);
    } else {
      _map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(points), padding: const EdgeInsets.all(48), maxZoom: 16));
    }
    _fitted = true;
    _scheduleLayout();
  }

  /// Re-lays the pins out once the camera stops moving (web: the map's `idle`).
  void _scheduleLayout() {
    _layoutTimer?.cancel();
    _layoutTimer = Timer(const Duration(milliseconds: 90), _layout);
  }

  void _layout() {
    if (!mounted || !_ready || !_fitted) return;
    final camera = _map.camera;
    final candidates = <PinCandidate>[];
    for (final p in _pins) {
      if (p.pricePerNight <= 0) continue; // no price, no pin (as on the web)
      final o = camera.getOffsetFromOrigin(LatLng(p.lat!, p.lng!));
      candidates.add(PinCandidate(id: p.id, label: _label(p), x: o.dx, y: o.dy));
    }
    var next = layoutPins(candidates, width: camera.nonRotatedSize.x, height: camera.nonRotatedSize.y, priorityIds: {for (final l in widget.resultListings) l.id});
    // The selected stay always shows its pin, even if the layout had no room.
    final sel = _selectedId;
    if (sel != null) {
      final c = candidates.where((c) => c.id == sel).firstOrNull;
      if (c != null) next = [for (final p in next) if (p.pin.id != sel) p, PlacedPin(c, PinVariant.pill)];
    }
    if (_samePlacement(next, _placed)) return;
    setState(() => _placed = next);
  }

  static bool _samePlacement(List<PlacedPin> a, List<PlacedPin> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].pin.id != b[i].pin.id || a[i].variant != b[i].variant) return false;
    }
    return true;
  }

  String _label(Listing p) {
    final v = p.pricePerNight;
    return '£${v == v.roundToDouble() ? v.toInt() : v}';
  }

  Future<void> _select(String id) async {
    setState(() {
      _selectedId = id;
      _selected = widget.resultListings.where((l) => l.id == id).firstOrNull;
    });
    _layout();
    if (_selected != null) return;
    try {
      final details = await publicRepo.mapCard(id);
      if (mounted && _selectedId == id) {
        final pin = _pins.where((p) => p.id == id).firstOrNull;
        setState(() => _selected = Listing({...?pin?.raw, ...details.raw}));
      }
    } catch (_) {
      // Keep the skeleton; a tap on another pin or the map dismisses it.
    }
  }

  void _clearSelection() {
    if (_selectedId == null) return;
    setState(() {
      _selectedId = null;
      _selected = null;
    });
    _layout();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final pinById = {for (final p in _pins) p.id: p};
    return Stack(children: [
      FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCenter: _london,
          initialZoom: 11,
          minZoom: 3,
          onMapReady: () {
            _ready = true;
            _fit();
          },
          onPositionChanged: (_, __) => _scheduleLayout(),
          onTap: (_, __) => _clearSelection(),
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'uk.co.ukstayhub.app',
            maxNativeZoom: 19,
            keepBuffer: 2,
            evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
          ),
          MarkerLayer(rotate: false, markers: [
            for (final p in _placed)
              if (pinById[p.pin.id] != null)
                Marker(
                  key: ValueKey(p.pin.id),
                  point: LatLng(pinById[p.pin.id]!.lat!, pinById[p.pin.id]!.lng!),
                  width: p.variant == PinVariant.dot && p.pin.id != _selectedId ? kDotSize : estimatePillWidth(p.pin.label),
                  height: p.variant == PinVariant.dot && p.pin.id != _selectedId ? kDotSize : kPillHeight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _select(p.pin.id),
                    child: p.variant == PinVariant.dot && p.pin.id != _selectedId ? const _Dot() : _PricePill(label: p.pin.label, selected: p.pin.id == _selectedId),
                  ),
                ),
          ]),
          const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
        ],
      ),
      if (_loading) const Positioned(top: 12, left: 0, right: 0, child: Center(child: CircularProgressIndicator(color: AppColors.green))),
      if (_failed && _pins.isEmpty)
        Positioned.fill(
          child: ColoredBox(
            color: Colors.white.withValues(alpha: 0.9),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(t.pick('Mapu sa nepodarilo načítať.', 'The map could not be loaded.'), textAlign: TextAlign.center, style: AppText.inter(size: 14, weight: FontWeight.w600, color: _ink)),
                  const SizedBox(height: 4),
                  Text(t.pick('Ubytovanie si môžete prehľadávať v zozname.', 'Browse accommodation in the list.'), textAlign: TextAlign.center, style: AppText.inter(size: 12, color: AppColors.neutral500)),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _load, child: Text(t.pick('Skúsiť znova', 'Try again'))),
                ]),
              ),
            ),
          ),
        ),
      if (_selectedId != null)
        Positioned(
          left: 0,
          right: 0,
          bottom: 20,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Stack(children: [
                  _selected == null
                      ? Container(height: 96, decoration: BoxDecoration(color: AppColors.neutral100, borderRadius: BorderRadius.circular(16)))
                      : _StayCard3(listing: _selected!, t: t),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Material(
                      color: Colors.white.withValues(alpha: 0.95),
                      elevation: 2,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _clearSelection,
                        child: SizedBox(width: 36, height: 36, child: Icon(Icons.close, size: 20, color: _ink, semanticLabel: t.pick('Zavrieť', 'Close'))),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}

class _Dot extends StatelessWidget {
  const _Dot();
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: _ink, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2), boxShadow: const [BoxShadow(color: Color(0x4D000000), blurRadius: 4, offset: Offset(0, 1))]),
        ),
      );
}

class _PricePill extends StatelessWidget {
  const _PricePill({required this.label, required this.selected});
  final String label;
  final bool selected;
  @override
  Widget build(BuildContext context) => Center(
        child: AnimatedScale(
          scale: selected ? 1.1 : 1,
          duration: const Duration(milliseconds: 150),
          child: Container(
            constraints: const BoxConstraints(minWidth: 52),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? _ink : Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: selected ? _ink : const Color(0xFFE5E5E5), width: selected ? 2 : 1.5),
              boxShadow: [BoxShadow(color: selected ? const Color(0x591A3A2E) : const Color(0x26000000), blurRadius: selected ? 12 : 6, offset: Offset(0, selected ? 4 : 2))],
            ),
            child: Text(label, maxLines: 1, style: AppText.inter(size: 12, weight: FontWeight.w700, color: selected ? Colors.white : _ink)),
          ),
        ),
      );
}

/// StayCard3.js — the compact card opened from a pin.
class _StayCard3 extends StatelessWidget {
  const _StayCard3({required this.listing, required this.t});
  final Listing listing;
  final Strings t;

  @override
  Widget build(BuildContext context) {
    final img = listing.images.isEmpty ? '' : listing.images.first;
    final loc = [listing.city, listing.country].where((s) => s.isNotEmpty).join(', ');
    final price = listing.pricePerNight;
    return Material(
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      elevation: 8,
      shadowColor: const Color(0x2E1A3A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: Color(0xFFDCE9E1))),
      child: InkWell(
        onTap: () => context.push('/listings/${listing.slug}'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 164),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                flex: 42,
                child: Stack(fit: StackFit.expand, children: [
                  img.isEmpty
                      ? const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFDCE9E1), Color(0xFFB9D2C2)])))
                      : NetImage(cloudinary(img, width: 360), cacheWidth: 360),
                  const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0x8C102B21), Color(0x00102B21)]))),
                  if (price > 0)
                    Positioned(
                      left: 12,
                      bottom: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(12)),
                        child: Text.rich(TextSpan(children: [
                          TextSpan(text: '£${price == price.roundToDouble() ? price.toInt() : price}', style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFF173C2E))),
                          TextSpan(text: ' ${t.pick('/ noc', '/ night')}', style: AppText.inter(size: 12, color: const Color(0xFF597066))),
                        ])),
                      ),
                    ),
                ]),
              ),
              Expanded(
                flex: 58,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.pick('UBYTOVANIE UK STAY HUB', 'UK STAY HUB STAY'), style: AppText.inter(size: 10, weight: FontWeight.w700, color: const Color(0xFF368565), letterSpacing: 1.6)),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.only(right: 28),
                        child: Text(listing.name(t.lang), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 16, weight: FontWeight.w600, color: const Color(0xFF173C2E), height: 1.35)),
                      ),
                      if (loc.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Icon(Icons.place_outlined, size: 16, color: Color(0xFF2D8A68)),
                          const SizedBox(width: 6),
                          Expanded(child: Text(loc, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 12, color: const Color(0xFF63776D), height: 1.35))),
                        ]),
                      ],
                    ]),
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(t.pick('Zobraziť ubytovanie', 'View accommodation'), style: AppText.inter(size: 12, weight: FontWeight.w600, color: const Color(0xFF237A59))),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_outward, size: 16, color: Color(0xFF237A59)),
                      ]),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
