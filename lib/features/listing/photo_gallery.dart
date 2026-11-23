import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/stay_card.dart';

/// listing-image-gallery: opens the white "all photos" grid, like ukstayhub.co.uk.
Future<void> openPhotoGallery(
  BuildContext context, {
  required List<String> images,
  required String listingId,
  String name = '',
  int index = 0,
}) {
  if (images.isEmpty) return Future.value();
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 150),
    reverseTransitionDuration: const Duration(milliseconds: 100),
    transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    pageBuilder: (_, __, ___) => PhotoGalleryPage(images: images, listingId: listingId, initial: index),
  ));
}

class PhotoGalleryPage extends ConsumerStatefulWidget {
  const PhotoGalleryPage({super.key, required this.images, required this.listingId, this.initial = 0});
  final List<String> images;
  final String listingId;
  final int initial;

  @override
  ConsumerState<PhotoGalleryPage> createState() => _PhotoGalleryPageState();
}

class _PhotoGalleryPageState extends ConsumerState<PhotoGalleryPage> {
  int? _viewer; // null = grid, else the photo shown in the viewer

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final imgs = widget.images;
    return PopScope(
      canPop: _viewer == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _viewer != null) setState(() => _viewer = null);
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Stack(children: [
          SafeArea(
            child: Column(children: [
              // Sticky bar: "All photos", like button, close.
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Expanded(
                    child: Text(t('GalleryAllPhotos', 'Všetky fotografie'),
                        style: AppText.inter(size: 18, weight: FontWeight.w600, color: AppColors.neutral900)),
                  ),
                  FavoriteButton(listingId: widget.listingId, size: 40, plain: true),
                  const SizedBox(width: 12),
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    customBorder: const CircleBorder(),
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(Icons.close, size: 24, color: AppColors.neutral900, semanticLabel: t('GalleryClose', 'Zavrieť galériu')),
                    ),
                  ),
                ]),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 4 / 3,
                  ),
                  itemCount: imgs.length,
                  itemBuilder: (_, i) => GestureDetector(
                    onTap: () => setState(() => _viewer = i),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: NetImage(cloudinary(imgs[i], width: 480), cacheWidth: 480),
                    ),
                  ),
                ),
              ),
            ]),
          ),
          if (_viewer != null)
            _Viewer(
              images: imgs,
              index: _viewer!,
              onChanged: (i) => setState(() => _viewer = i),
              onBack: () => setState(() => _viewer = null),
              onClose: () => setState(() => _viewer = null),
            ),
        ]),
      ),
    );
  }
}

/// SharedModal: dimmed full-screen photo, swipe, arrows, counter and dots.
class _Viewer extends ConsumerStatefulWidget {
  const _Viewer({required this.images, required this.index, required this.onChanged, required this.onBack, required this.onClose});
  final List<String> images;
  final int index;
  final ValueChanged<int> onChanged;
  final VoidCallback onBack;
  final VoidCallback onClose;

  @override
  ConsumerState<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends ConsumerState<_Viewer> {
  late final PageController _c = PageController(initialPage: widget.index);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _go(int i) => _c.animateToPage(i, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final n = widget.images.length;
    final i = widget.index;
    final pad = MediaQuery.paddingOf(context);

    Widget round(IconData icon, VoidCallback onTap, String label) => Semantics(
          button: true,
          label: label,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(color: Color(0x8C000000), shape: BoxShape.circle),
              child: Icon(icon, size: 24, color: Colors.white),
            ),
          ),
        );

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xCC000000),
        child: Stack(children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _c,
              itemCount: n,
              onPageChanged: widget.onChanged,
              itemBuilder: (_, k) => Padding(
                padding: EdgeInsets.fromLTRB(16, 56 + pad.top, 16, 64 + pad.bottom),
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: NetImage(cloudinary(widget.images[k], width: 960, crop: false), fit: BoxFit.contain, cacheWidth: 960),
                  ),
                ),
              ),
            ),
          ),
          // "‹ All photos"
          Positioned(
            left: 16,
            top: 16 + pad.top,
            child: GestureDetector(
              onTap: widget.onBack,
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(color: const Color(0x8C000000), borderRadius: BorderRadius.circular(999)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.arrow_back, size: 20, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(t('GalleryAllPhotos', 'Všetky fotografie'), style: AppText.inter(size: 14, weight: FontWeight.w500, color: Colors.white)),
                ]),
              ),
            ),
          ),
          Positioned(right: 16, top: 16 + pad.top, child: round(Icons.close, widget.onClose, t('GalleryClose', 'Zavrieť galériu'))),
          if (i > 0)
            Positioned(left: 12, top: 0, bottom: 0, child: Center(child: round(Icons.chevron_left_rounded, () => _go(i - 1), t('PhotoPrevious', 'Predchádzajúca fotografia')))),
          if (i < n - 1)
            Positioned(right: 12, top: 0, bottom: 0, child: Center(child: round(Icons.chevron_right_rounded, () => _go(i + 1), t('PhotoNext', 'Ďalšia fotografia')))),
          Positioned(
            left: 0,
            right: 0,
            bottom: 20 + pad.bottom,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${i + 1} / $n', style: AppText.inter(size: 12, weight: FontWeight.w500, color: const Color(0xD9FFFFFF))),
              const SizedBox(height: 8),
              SizedBox(
                width: MediaQuery.sizeOf(context).width * 0.9,
                child: Wrap(alignment: WrapAlignment.center, spacing: 6, children: [
                  for (var k = 0; k < n; k++)
                    GestureDetector(
                      onTap: () => _go(k),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: k == i ? 20 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: k == i ? Colors.white : const Color(0x73FFFFFF),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
