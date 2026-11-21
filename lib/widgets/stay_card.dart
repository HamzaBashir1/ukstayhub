import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/auth.dart';
import '../state/providers.dart';
import 'common.dart';

/// components/GridFeaturePlaces/GallerySlider.js – swipeable photos with dots.
class GallerySlider extends StatefulWidget {
  const GallerySlider({
    super.key,
    required this.images,
    this.aspectRatio = 3 / 2,
    this.onTap,
    this.radius = const BorderRadius.vertical(top: Radius.circular(20)),
    this.width = 600,
  });
  final List<String> images;
  final double aspectRatio;
  final VoidCallback? onTap;
  final BorderRadius radius;
  final int width;

  @override
  State<GallerySlider> createState() => _GallerySliderState();
}

class _GallerySliderState extends State<GallerySlider> {
  final _page = PageController();
  int _index = 0;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final imgs = widget.images.isEmpty ? const [''] : widget.images;
    const maxDots = 6;
    var start = (_index - maxDots ~/ 2).clamp(0, imgs.length);
    final end = (start + maxDots).clamp(0, imgs.length);
    if (end - start < maxDots) start = (end - maxDots).clamp(0, imgs.length);

    return ClipRRect(
      borderRadius: widget.radius,
      child: AspectRatio(
        aspectRatio: widget.aspectRatio,
        child: Stack(fit: StackFit.expand, children: [
          PageView.builder(
            controller: _page,
            itemCount: imgs.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => GestureDetector(
              onTap: widget.onTap,
              child: NetImage(cloudinary(imgs[i], width: widget.width), cacheWidth: widget.width),
            ),
          ),
          if (imgs.length > 1)
            Positioned(
              bottom: 8,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = start; i < end; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _index ? 8 : 6,
                      height: i == _index ? 8 : 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _index ? Colors.white : Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                ],
              ),
            ),
        ]),
      ),
    );
  }
}

/// components/GridFeaturePlaces/StayCardFeatured.js
class StayCard extends ConsumerWidget {
  const StayCard({super.key, required this.listing, this.showFavorite = true});
  final Listing listing;
  final bool showFavorite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final lang = t.lang;
    final rating = listing.rating;
    final country = _country(listing.country, lang);
    void open() => context.push('/listings/${listing.slug}');

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: open,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.neutral100),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Stack(children: [
              GallerySlider(images: listing.images.take(8).toList(), onTap: open),
              Positioned(
                top: 16,
                right: 4,
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(50),
                    boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 12, offset: Offset(0, 4))],
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.check_rounded, size: 20, color: AppColors.green),
                    const SizedBox(width: 6),
                    Text(t('StayHubVerified', 'UK Stay Hub overené'),
                        style: AppText.inter(size: 13.6, weight: FontWeight.w600, color: AppColors.forest)),
                  ]),
                ),
              ),
              if (showFavorite) Positioned(top: 12, left: 12, child: FavoriteButton(listingId: listing.id)),
            ]),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  _cap(listing.name(lang)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.fraunces(size: 22, color: Colors.black),
                ),
                const SizedBox(height: 8),
                Text(
                  [if (listing.city.isNotEmpty) listing.city, country].join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.inter(size: 14, color: AppColors.slate),
                ),
                const SizedBox(height: 16),
                const Divider(color: Color(0x0F2A2A2A), height: 1),
                const SizedBox(height: 16),
                Row(children: [
                  Text(money(listing.pricePerNight), style: AppText.dmSans(size: 20, weight: FontWeight.w700, color: AppColors.greenPrice)),
                  const SizedBox(width: 4),
                  Text('/${t('night', 'noc')}', style: AppText.inter(size: 14, color: AppColors.slate)),
                  const Spacer(),
                  const Icon(Icons.star_rounded, size: 18, color: AppColors.yellowStar),
                  const SizedBox(width: 4),
                  Text(rating > 0 ? rating.toStringAsFixed(1) : t('New', 'Nové'),
                      style: AppText.dmSans(size: 16, weight: FontWeight.w500, color: const Color(0xFF2A2A2A))),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String _country(String c, String lang) {
    final n = c.trim().toLowerCase();
    if (n.isEmpty || n == 'uk' || n == 'gb' || n == 'great britain' || n == 'united kingdom' || n == 'england') {
      return 'United Kingdom';
    }
    return c;
  }
}

/// SkeletonCard.js
class StayCardSkeleton extends StatelessWidget {
  const StayCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.neutral100),
        ),
        child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            child: AspectRatio(aspectRatio: 3 / 2, child: Shimmer()),
          ),
          Padding(
            padding: EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Shimmer(height: 22, width: 200, radius: 6),
              SizedBox(height: 10),
              Shimmer(height: 14, width: 120, radius: 6),
              SizedBox(height: 24),
              Shimmer(height: 18, width: 90, radius: 6),
            ]),
          ),
        ]),
      );
}

/// LikeSaveBtns.js – heart toggle for saved stays.
class FavoriteButton extends ConsumerWidget {
  const FavoriteButton({super.key, required this.listingId, this.size = 38, this.bordered = false, this.plain = false});
  final String listingId;
  final double size;
  final bool bordered;
  /// Bare icon, no circle (the listing page's like button).
  final bool plain;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final saved = ref.watch(favoritesProvider).valueOrNull?.contains(listingId) ?? false;
    return Material(
      color: plain ? Colors.transparent : Colors.white.withValues(alpha: bordered ? 1 : 0.92),
      shape: CircleBorder(side: bordered ? const BorderSide(color: AppColors.neutral200) : BorderSide.none),
      elevation: (bordered || plain) ? 0 : 1,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () async {
          final auth = ref.read(authProvider);
          if (!auth.loggedIn) {
            toast(context, t('PleaseLoginToSave', t.pick('Prihláste sa, aby ste si mohli uložiť ubytovanie.', 'Log in to save stays.')), error: true);
            context.push('/login');
            return;
          }
          if (auth.isHost) {
            toast(context, t.pick('Ukladanie je dostupné v účte cestovateľa.', 'Saving is available in your traveller account.'), error: true);
            return;
          }
          try {
            await ref.read(favoritesProvider.notifier).toggle(listingId);
          } catch (e) {
            if (context.mounted) toast(context, errorText(e), error: true);
          }
        },
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(saved ? Icons.favorite : Icons.favorite_border,
              size: plain ? 24 : size * 0.5, color: saved ? const Color(0xFFEF4444) : (plain ? AppColors.neutral800 : AppColors.neutral700)),
        ),
      ),
    );
  }
}
