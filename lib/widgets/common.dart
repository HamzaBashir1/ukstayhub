import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/theme.dart';

// ───────────────────────────── Images ─────────────────────────────
/// Network image with the site's shimmer placeholder and a decode size cap,
/// so a 4000px Cloudinary original never sits in memory at full size.
class NetImage extends StatelessWidget {
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.width, this.height, this.cacheWidth = 800});
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return _placeholder();
    if (url.startsWith('assets/')) {
      return Image.asset(url, fit: fit, width: width, height: height, cacheWidth: cacheWidth);
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      width: width,
      height: height,
      memCacheWidth: cacheWidth,
      fadeInDuration: const Duration(milliseconds: 250),
      placeholder: (_, __) => const Shimmer(),
      errorWidget: (_, __, ___) => _placeholder(),
    );
  }

  Widget _placeholder() => Container(
        width: width,
        height: height,
        color: AppColors.neutral200,
        alignment: Alignment.center,
        child: const Icon(Icons.image_outlined, color: AppColors.neutral400, size: 32),
      );
}

/// `shimmer-glow` from globals.css.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, this.radius = 0, this.height, this.width});
  final double radius;
  final double? height;
  final double? width;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            begin: Alignment(-1.5 + 3 * _c.value, 0),
            end: Alignment(-0.5 + 3 * _c.value, 0),
            colors: const [Color(0xFFE5E5E5), Color(0xFFF5F5F5), Color(0xFFE5E5E5)],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── Buttons ─────────────────────────────
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.icon,
    this.color = AppColors.green,
    this.radius = 12,
    this.height = 52,
    this.expand = true,
    this.textColor = Colors.white,
    this.shadow = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;
  final Color color;
  final Color textColor;
  final double radius;
  final double height;
  final bool expand;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final child = loading
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[Icon(icon, size: 20, color: textColor), const SizedBox(width: 10)],
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.inter(size: 16, weight: FontWeight.w600, color: textColor)),
              ),
            ],
          );
    return Container(
      width: expand ? double.infinity : null,
      height: height,
      decoration: shadow
          ? BoxDecoration(borderRadius: BorderRadius.circular(radius), boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.30), blurRadius: 20, offset: const Offset(0, 8)),
            ])
          : null,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          disabledBackgroundColor: color.withValues(alpha: loading ? 1 : 0.5),
          foregroundColor: textColor,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        ),
        child: child,
      ),
    );
  }
}

class OutlineBtn extends StatelessWidget {
  const OutlineBtn({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = AppColors.forest,
    this.borderColor = AppColors.neutral200,
    this.height = 50,
    this.expand = true,
    this.radius = 12,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color color;
  final Color borderColor;
  final double height;
  final bool expand;
  final double radius;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: expand ? double.infinity : null,
        height: height,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: color,
            side: BorderSide(color: borderColor),
            padding: const EdgeInsets.symmetric(horizontal: 18),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis, style: AppText.inter(size: 15, weight: FontWeight.w600, color: color)),
              ),
            ],
          ),
        ),
      );
}

class LinkText extends StatelessWidget {
  const LinkText(this.text, {super.key, required this.onTap, this.color = AppColors.greenText, this.arrow = false, this.size = 15});
  final String text;
  final VoidCallback onTap;
  final Color color;
  final bool arrow;
  final double size;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(text, style: AppText.inter(size: size, weight: FontWeight.w600, color: color)),
            if (arrow) ...[const SizedBox(width: 6), Icon(Icons.arrow_forward, size: 16, color: color)],
          ]),
        ),
      );
}

// ───────────────────────────── Inputs ─────────────────────────────
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.required = false});
  final String text;
  final bool required;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: text, style: AppText.inter(size: 14, weight: FontWeight.w500, color: AppColors.forest)),
          if (required) TextSpan(text: ' *', style: AppText.inter(size: 14, color: Colors.red)),
        ])),
      );
}

class StayHubField extends StatefulWidget {
  const StayHubField({
    super.key,
    this.label,
    this.controller,
    this.hint,
    this.required = false,
    this.password = false,
    this.keyboard,
    this.maxLines = 1,
    this.errorText,
    this.onChanged,
    this.autofill,
    this.textInputAction,
    this.prefix,
    this.enabled = true,
  });
  final String? label;
  final TextEditingController? controller;
  final String? hint;
  final bool required;
  final bool password;
  final TextInputType? keyboard;
  final int maxLines;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final Iterable<String>? autofill;
  final TextInputAction? textInputAction;
  final Widget? prefix;
  final bool enabled;

  @override
  State<StayHubField> createState() => _StayHubFieldState();
}

class _StayHubFieldState extends State<StayHubField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (widget.label != null) FieldLabel(widget.label!, required: widget.required),
      TextField(
        controller: widget.controller,
        obscureText: widget.password && _obscure,
        keyboardType: widget.keyboard,
        maxLines: widget.password ? 1 : widget.maxLines,
        onChanged: widget.onChanged,
        enabled: widget.enabled,
        autofillHints: widget.autofill,
        textInputAction: widget.textInputAction,
        style: AppText.inter(size: 15, color: const Color(0xFF111827)),
        decoration: InputDecoration(
          hintText: widget.hint,
          errorText: widget.errorText,
          prefixIcon: widget.prefix,
          suffixIcon: widget.password
              ? IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      color: const Color(0xFF94A3B8), size: 20),
                )
              : null,
        ),
      ),
    ]);
  }
}

/// NcInputNumber: − value + stepper used for guests, rooms, beds.
class Counter extends StatelessWidget {
  const Counter({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 99,
  });
  final String label;
  final String? description;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, bool enabled, VoidCallback onTap) => InkWell(
          onTap: enabled ? onTap : null,
          customBorder: const CircleBorder(),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: enabled ? AppColors.neutral400 : AppColors.neutral200),
            ),
            child: Icon(icon, size: 18, color: enabled ? AppColors.neutral700 : AppColors.neutral300),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: AppText.inter(size: 15, weight: FontWeight.w600, color: AppColors.neutral800)),
            if (description != null && description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(description!, style: AppText.inter(size: 13, color: AppColors.neutral500)),
              ),
          ]),
        ),
        btn(Icons.remove, value > min, () => onChanged(value - 1)),
        SizedBox(
          width: 40,
          child: Text('$value',
              textAlign: TextAlign.center, style: AppText.inter(size: 16, weight: FontWeight.w600, color: AppColors.neutral900)),
        ),
        btn(Icons.add, value < max, () => onChanged(value + 1)),
      ]),
    );
  }
}

// ───────────────────────────── Text blocks ─────────────────────────────
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.subtitle, this.center = false, this.trailing});
  final String title;
  final String? subtitle;
  final bool center;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final col = Column(
      crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(title, textAlign: center ? TextAlign.center : TextAlign.start, style: AppText.sectionTitle),
        if (subtitle != null) ...[
          const SizedBox(height: 12),
          Text(subtitle!, textAlign: center ? TextAlign.center : TextAlign.start, style: AppText.sectionSubtitle),
        ],
      ],
    );
    if (trailing == null) return col;
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: col), trailing!]);
  }
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.bg = AppColors.mint, this.fg = AppColors.green, this.icon, this.border});
  final String text;
  final Color bg;
  final Color fg;
  final IconData? icon;
  final Color? border;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: border == null ? null : Border.all(color: border!),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 5)],
          Text(text, style: AppText.inter(size: 12, weight: FontWeight.w600, color: fg)),
        ]),
      );
}

class StarRow extends StatelessWidget {
  const StarRow({super.key, required this.value, this.size = 16, this.color = AppColors.star});
  final double value;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(5, (i) {
          final f = value - i;
          final icon = f >= 0.75 ? Icons.star_rounded : (f >= 0.25 ? Icons.star_half_rounded : Icons.star_outline_rounded);
          return Icon(icon, size: size, color: f > 0 ? color : AppColors.neutral300);
        }),
      );
}

// ───────────────────────────── States ─────────────────────────────
class LoadingView extends StatelessWidget {
  const LoadingView({super.key});
  @override
  Widget build(BuildContext context) =>
      const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator(color: AppColors.green)));
}

/// The app is English (UK) only; kept so existing two-language call sites compile.
String _pick(BuildContext context, String other, String en) => en;

/// True when [e] means the phone has no connection to the server.
bool isOfflineError(Object? e) => e is ApiException && e.isOffline;

/// Full-screen error state. Pass [error] so a lost connection shows the clear
/// "No connection – tap to retry" message instead of a technical one; the
/// whole area is tappable then, not just the button.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.error, this.onRetry, this.retryLabel});
  final String message;
  final Object? error;
  final VoidCallback? onRetry;
  final String? retryLabel;

  @override
  Widget build(BuildContext context) {
    final offline = isOfflineError(error);
    final label = retryLabel ?? _pick(context, 'Skúsiť znova', 'Try again');
    final content = Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(offline ? Icons.wifi_off_rounded : Icons.cloud_off_outlined, size: 40, color: AppColors.neutral400),
          const SizedBox(height: 12),
          if (offline) ...[
            Text(_pick(context, 'Žiadne pripojenie', 'No connection'),
                textAlign: TextAlign.center,
                style: AppText.inter(size: 17, weight: FontWeight.w600, color: AppColors.forest)),
            const SizedBox(height: 6),
            Text(
                onRetry != null
                    ? _pick(context, 'Skontrolujte internet a ťuknite pre opakovanie.', 'Check your internet and tap to retry.')
                    : _pick(context, 'Skontrolujte pripojenie na internet.', 'Check your internet connection.'),
                textAlign: TextAlign.center,
                style: AppText.inter(size: 15, color: AppColors.mutedGreen)),
          ] else
            Text(message, textAlign: TextAlign.center, style: AppText.inter(size: 15, color: AppColors.mutedGreen)),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            OutlineBtn(label: label, onPressed: onRetry, expand: false, icon: Icons.refresh),
          ],
        ]),
      ),
    );
    if (!offline || onRetry == null) return content;
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onRetry, child: content);
  }
}

/// Compact, tappable error box for one section of a page (e.g. a listing row
/// on the home page), so the rest of the page stays usable.
class InlineErrorBox extends StatelessWidget {
  const InlineErrorBox({super.key, required this.error, required this.onRetry, this.minHeight = 144});
  final Object error;
  final VoidCallback onRetry;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final offline = isOfflineError(error);
    final title = offline
        ? _pick(context, 'Žiadne pripojenie', 'No connection')
        : _pick(context, 'Nepodarilo sa načítať', "Couldn't load this");
    return Material(
      color: AppColors.neutral50,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onRetry,
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(minHeight: minHeight),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(offline ? Icons.wifi_off_rounded : Icons.cloud_off_outlined, size: 32, color: AppColors.neutral400),
            const SizedBox(height: 10),
            Text(title,
                textAlign: TextAlign.center,
                style: AppText.inter(size: 16, weight: FontWeight.w600, color: AppColors.forest)),
            const SizedBox(height: 4),
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.refresh, size: 16, color: AppColors.green),
              const SizedBox(width: 6),
              Text(_pick(context, 'Ťuknite pre opakovanie', 'Tap to retry'),
                  style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.green)),
            ]),
          ]),
        ),
      ),
    );
  }
}

class EmptyBox extends StatelessWidget {
  const EmptyBox(this.text, {super.key, this.icon = Icons.search_off_rounded});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(16)),
        child: Column(children: [
          Icon(icon, size: 36, color: AppColors.neutral400),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center, style: AppText.inter(size: 16, color: AppColors.neutral500)),
        ]),
      );
}

// ───────────────────────────── Feedback ─────────────────────────────
void toast(BuildContext context, String message, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Row(children: [
      Icon(error ? Icons.error_outline : Icons.check_circle_outline,
          color: error ? const Color(0xFFF87171) : const Color(0xFF4ADE80), size: 20),
      const SizedBox(width: 10),
      Expanded(child: Text(message)),
    ]),
    duration: const Duration(seconds: 4),
  ));
}

String errorText(Object e) => e is ApiException ? e.message : 'Something went wrong. Please try again.';

/// Bottom sheet chrome used by the site's mobile dialogs (handle + title + ×).
Future<T?> showStayHubSheet<T>(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
  Widget? action,
  bool fullHeight = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    builder: (ctx) {
      final media = MediaQuery.of(ctx);
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * (fullHeight ? 0.94 : 0.9)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.neutral300, borderRadius: BorderRadius.circular(4))),
            SizedBox(
              height: 52,
              // NavigationToolbar keeps the title centred when it fits, and
              // shifts/ellipsizes it so it never overlaps the action or ×.
              child: NavigationToolbar(
                middleSpacing: 12,
                leading: action == null
                    ? const SizedBox(width: 48)
                    : Padding(padding: const EdgeInsets.only(left: 8), child: action),
                middle: Text(title,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.inter(size: 16, weight: FontWeight.w600, color: AppColors.neutral800)),
                trailing: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: IconButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    icon: const Icon(Icons.close, color: AppColors.neutral500),
                  ),
                ),
              ),
            ),
            const Divider(),
            Flexible(child: builder(ctx)),
          ]),
        ),
      );
    },
  );
}
