import 'package:intl/intl.dart';

import 'config.dart';

/// Prices are shown in pounds sterling (GBP), the app's only currency.
const String currencySymbol = '£';
const String currencyCode = 'GBP';

final _gbp0 = NumberFormat.currency(locale: 'en_GB', symbol: currencySymbol, decimalDigits: 0);
final _gbp2 = NumberFormat.currency(locale: 'en_GB', symbol: currencySymbol, decimalDigits: 2);

/// `£1,250` for whole pounds, `£12.50` otherwise (or always with [decimals]).
String money(num value, {bool decimals = false}) {
  final v = value.toDouble();
  if (!decimals && v == v.roundToDouble()) return _gbp0.format(v);
  return _gbp2.format(v);
}

String moneyCents(num cents) => money(cents / 100, decimals: cents % 100 != 0);

final _iso = DateFormat('yyyy-MM-dd');
String isoDay(DateTime d) => _iso.format(d);

DateTime? parseDay(String? s) {
  if (s == null || s.isEmpty) return null;
  final d = DateTime.tryParse(s);
  if (d == null) return null;
  return DateTime(d.year, d.month, d.day);
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

int nightsBetween(DateTime? a, DateTime? b) {
  if (a == null || b == null) return 0;
  return dateOnly(b).difference(dateOnly(a)).inDays;
}

String shortDate(DateTime d, String lang) => DateFormat('d MMM', 'en_GB').format(d);

String longDate(DateTime d, String lang) => DateFormat('d MMMM yyyy', 'en_GB').format(d);

String dotDate(DateTime d) => DateFormat('dd/MM/yyyy').format(d);

String monthTitle(DateTime d, String lang) {
  final s = DateFormat('LLLL yyyy', 'en_GB').format(d);
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

String rangeLabel(DateTime? a, DateTime? b, String lang) {
  if (a == null) return '';
  if (b == null) return shortDate(a, lang);
  return '${shortDate(a, lang)} – ${shortDate(b, lang)}';
}

String titleCase(String s) => s
    .split(' ')
    .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
    .join(' ');

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  return parts.take(2).map((p) => p[0]).join().toUpperCase();
}

/// Same transformation as GallerySlider.optimizeCloudinary on the site, but
/// asking for WebP explicitly (Flutter decodes WebP everywhere; f_auto may
/// pick AVIF, which it does not).
String cloudinary(String? url, {int width = 600, double ratio = 0.75, bool crop = true}) {
  if (url == null || url.isEmpty) return '';
  if (!url.contains('res.cloudinary.com') || !url.contains('/upload/')) return url;
  final h = (width * ratio).round();
  final t = crop ? 'f_webp,q_auto:eco,w_$width,h_$h,c_fill' : 'f_webp,q_auto,w_$width,c_limit';
  return url.replaceFirst('/upload/', '/upload/$t/');
}

String sitePath(String path) => '${AppConfig.siteUrl}$path';

/// Same key as createSearchKey on the site: lowercase, no diacritics.
String searchKey(String? s) {
  if (s == null) return '';
  const from = 'áäčďéěíĺľňóôöŕřšťúůüýžÁÄČĎÉĚÍĹĽŇÓÔÖŔŘŠŤÚŮÜÝŽ';
  const to = 'aacdeeillnooorrstuuuyzAACDEEILLNOOORRSTUUUYZ';
  final b = StringBuffer();
  for (final ch in s.trim().split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}
