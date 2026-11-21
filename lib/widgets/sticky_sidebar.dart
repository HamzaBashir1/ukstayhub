import 'package:flutter/widgets.dart';

/// `sticky top-28` — rides along with the scroll inside the two-column row,
/// stopping at the row's bottom edge.
class StickySidebar extends StatefulWidget {
  const StickySidebar(
      {super.key, required this.scroll, required this.rowKey, required this.child});
  final ScrollController scroll;
  final GlobalKey rowKey;
  final Widget child;
  @override
  State<StickySidebar> createState() => _StickySidebarState();
}

class _StickySidebarState extends State<StickySidebar> {
  final _cardKey = GlobalKey();
  double _dy = 0;

  @override
  void initState() {
    super.initState();
    widget.scroll.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (!mounted) return;
    final row = widget.rowKey.currentContext?.findRenderObject() as RenderBox?;
    final card = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    if (row == null || card == null || !row.attached || !card.attached) return;
    final rowTop = row.localToGlobal(Offset.zero).dy;
    final travel =
        (row.size.height - card.size.height).clamp(0.0, double.infinity);
    final dy = (112 - rowTop).clamp(0.0, travel);
    if ((dy - _dy).abs() > 0.5) setState(() => _dy = dy);
  }

  @override
  Widget build(BuildContext context) {
    // Re-measure after each layout (the card's height changes with the price).
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
    return Align(
      alignment: Alignment.topCenter,
      child: Transform.translate(
          offset: Offset(0, _dy),
          child: KeyedSubtree(key: _cardKey, child: widget.child)),
    );
  }
}
