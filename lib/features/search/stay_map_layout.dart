import 'dart:math' as math;

/// Pin layout for the /mapa map — a port of `layoutPins` in
/// frontend/.../listing-stay-map/component/ListingMap.js, so the app and the
/// website decide the same way which stays get a price pill, which fall back to
/// a dot and which are hidden: only pins inside the viewport are placed, pill
/// slots go first to stays on the current results page, and a pin that would
/// overlap a pill becomes a small dot (or is dropped if even the dot has no room).
const double kPillHeight = 28;
const double kPillGap = 4;
const double kDotSize = 14;
const int kMaxPricePills = 60;
const int kMaxDots = 150;
const double kViewportMargin = 40;

enum PinVariant { pill, dot }

class PinCandidate {
  const PinCandidate({required this.id, required this.label, required this.x, required this.y});
  final String id;
  final String label;
  final double x; // screen px, relative to the map's top-left
  final double y;
}

class PlacedPin {
  const PlacedPin(this.pin, this.variant);
  final PinCandidate pin;
  final PinVariant variant;
}

double estimatePillWidth(String label) => math.max(52, label.length * 7.5 + 22);

class _Box {
  _Box(double x, double y, double w, double h, double gap)
      : left = x - w / 2 - gap,
        right = x + w / 2 + gap,
        top = y - h / 2 - gap,
        bottom = y + h / 2 + gap;
  final double left, right, top, bottom;
  bool overlaps(_Box o) => left < o.right && o.left < right && top < o.bottom && o.top < bottom;
}

/// [pins] are in render order; [priorityIds] are the stays on the current results page.
/// Dots come first in the result so pills paint above them.
List<PlacedPin> layoutPins(List<PinCandidate> pins, {required double width, required double height, Set<String> priorityIds = const {}}) {
  if (width <= 0 || height <= 0) return const [];
  final visible = <(int, PinCandidate)>[];
  for (var i = 0; i < pins.length; i++) {
    final p = pins[i];
    if (p.x < -kViewportMargin || p.x > width + kViewportMargin || p.y < -kViewportMargin || p.y > height + kViewportMargin) continue;
    visible.add((i, p));
  }
  visible.sort((a, b) {
    final pa = priorityIds.contains(a.$2.id) ? 0 : 1, pb = priorityIds.contains(b.$2.id) ? 0 : 1;
    return pa != pb ? pa - pb : a.$1 - b.$1;
  });

  final pillBoxes = <_Box>[];
  final placed = <PlacedPin>[];
  final leftovers = <PinCandidate>[];
  for (final (_, c) in visible) {
    final box = _Box(c.x, c.y, estimatePillWidth(c.label), kPillHeight, kPillGap);
    if (pillBoxes.length < kMaxPricePills && !pillBoxes.any(box.overlaps)) {
      pillBoxes.add(box);
      placed.add(PlacedPin(c, PinVariant.pill));
    } else {
      leftovers.add(c);
    }
  }

  final dotBoxes = <_Box>[];
  final dots = <PlacedPin>[];
  for (final c in leftovers) {
    if (dotBoxes.length >= kMaxDots) break;
    final box = _Box(c.x, c.y, kDotSize, kDotSize, 2);
    if (pillBoxes.any(box.overlaps) || dotBoxes.any(box.overlaps)) continue;
    dotBoxes.add(box);
    dots.add(PlacedPin(c, PinVariant.dot));
  }
  return [...dots, ...placed];
}
