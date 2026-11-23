import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/format.dart';
import '../core/theme.dart';

/// The site's date-range calendar (react-datepicker restyled in globals.css):
/// selected ends #319a7a / white, in-range #d2f8e8 / #173f32, disabled grey.
///
/// [nightBlocked] marks nights that cannot be booked. A check-out may land on
/// the first blocked night (the guest leaves that morning), but a range may
/// not span a blocked night.
class RangeCalendar extends StatelessWidget {
  const RangeCalendar({
    super.key,
    required this.start,
    required this.end,
    required this.onChanged,
    required this.lang,
    this.nightBlocked,
    this.months = 12,
    this.minNights = 1,
    this.maxNights = 365,
    this.onRuleViolation,
    this.inline = false,
    this.sideBySide = false,
    this.monthOffset = 0,
  });

  /// Non-scrolling, website-style: [months] months stacked from [monthOffset].
  final bool inline;

  /// With [inline]: lay the months out in a row (the website does from `sm`).
  final bool sideBySide;
  final int monthOffset;
  final DateTime? start;
  final DateTime? end;
  final void Function(DateTime? start, DateTime? end) onChanged;
  final bool Function(DateTime day)? nightBlocked;
  final String lang;
  final int months;
  final int minNights;
  final int maxNights;
  final void Function(String reason)? onRuleViolation;

  bool _blocked(DateTime d) => nightBlocked?.call(d) ?? false;

  void _tap(DateTime day) {
    final today = dateOnly(DateTime.now());
    if (day.isBefore(today)) return;
    final s = start, e = end;
    if (s == null || e != null || !day.isAfter(s)) {
      if (_blocked(day)) {
        onRuleViolation?.call('blocked');
        return;
      }
      onChanged(day, null);
      return;
    }
    // Choosing check-out: every night in [s, day) must be free.
    for (var d = s; d.isBefore(day); d = d.add(const Duration(days: 1))) {
      if (_blocked(d)) {
        onRuleViolation?.call('blocked');
        onChanged(_blocked(day) ? null : day, null);
        return;
      }
    }
    final n = nightsBetween(s, day);
    if (n < minNights) {
      onRuleViolation?.call('min');
      return;
    }
    if (n > maxNights) {
      onRuleViolation?.call('max');
      return;
    }
    onChanged(s, day);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final first = DateTime(now.year, now.month + monthOffset);
    final weekdays = _weekdays(lang);
    if (inline) {
      Widget month(int i) => _Month(
            month: DateTime(first.year, first.month + i),
            lang: lang,
            weekdays: weekdays,
            start: start,
            end: end,
            blocked: _blocked,
            onTap: _tap,
            inline: true,
          );
      if (sideBySide && months > 1) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < months; i++) ...[if (i > 0) const SizedBox(width: 40), Expanded(child: month(i))],
        ]);
      }
      return Column(children: [for (var i = 0; i < months; i++) month(i)]);
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: months,
      itemBuilder: (_, i) {
        final month = DateTime(first.year, first.month + i);
        return _Month(
          month: month,
          lang: lang,
          weekdays: weekdays,
          start: start,
          end: end,
          blocked: _blocked,
          onTap: _tap,
        );
      },
    );
  }

  static List<String> _weekdays(String lang) {
    // Monday-first, two letters, like the site.
    final f = DateFormat.E('en_GB');
    final monday = DateTime(2024, 1, 1);
    return List.generate(7, (i) {
      final s = f.format(monday.add(Duration(days: i)));
      return s.length > 2 ? s.substring(0, 2) : s;
    });
  }
}

class _Month extends StatelessWidget {
  const _Month({
    required this.month,
    required this.lang,
    required this.weekdays,
    required this.start,
    required this.end,
    required this.blocked,
    required this.onTap,
    this.inline = false,
  });
  final bool inline;
  final DateTime month;
  final String lang;
  final List<String> weekdays;
  final DateTime? start;
  final DateTime? end;
  final bool Function(DateTime) blocked;
  final void Function(DateTime) onTap;

  @override
  Widget build(BuildContext context) {
    final today = dateOnly(DateTime.now());
    final days = DateUtils.getDaysInMonth(month.year, month.month);
    final lead = (DateTime(month.year, month.month, 1).weekday + 6) % 7;
    final cells = lead + days;
    final rows = (cells / 7).ceil();

    return Padding(
      padding: EdgeInsets.only(bottom: inline ? 24 : 20),
      child: Column(children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: inline ? 12 : 10),
          child: Text(monthTitle(month, lang),
              style: AppText.inter(size: inline ? 15 : 16, weight: FontWeight.w600, color: inline ? const Color(0xFF111827) : AppColors.neutral800)),
        ),
        Row(
          children: [
            for (final w in weekdays)
              Expanded(
                child: SizedBox(
                  height: inline ? 36 : 30,
                  child: Center(
                    child: Text(inline ? (w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)) : w.toUpperCase(),
                        style: inline
                            ? AppText.inter(size: 14, weight: FontWeight.w500, color: AppColors.neutral600)
                            : AppText.inter(size: 10, weight: FontWeight.w600, color: AppColors.neutral400)),
                  ),
                ),
              ),
          ],
        ),
        for (var r = 0; r < rows; r++)
          Row(children: [
            for (var c = 0; c < 7; c++)
              Expanded(child: _cell(r * 7 + c - lead + 1, days, today)),
          ]),
      ]),
    );
  }

  Widget _cell(int dayNum, int days, DateTime today) {
    if (dayNum < 1 || dayNum > days) return const SizedBox(height: 44);
    final d = DateTime(month.year, month.month, dayNum);
    final past = d.isBefore(today);
    final isBlocked = !past && blocked(d);
    final s = start, e = end;
    final isStart = s != null && d == s;
    final isEnd = e != null && d == e;
    final inRange = s != null && e != null && d.isAfter(s) && d.isBefore(e);
    final selected = isStart || isEnd;
    // Check-out on a blocked night is allowed when the preceding nights are free.
    final disabled = past || (isBlocked && !(s != null && e == null && d.isAfter(s)));

    Color? band;
    if (inRange || (isStart && e != null) || isEnd) band = AppColors.rangeBg;

    return GestureDetector(
      onTap: disabled ? null : () => onTap(d),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 44,
        child: Stack(alignment: Alignment.center, children: [
          if (band != null)
            Positioned.fill(
              top: 4,
              bottom: 4,
              left: isStart ? 22 : 0,
              right: isEnd ? 22 : 0,
              child: ColoredBox(color: band),
            ),
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? AppColors.greenListing : (inline && isBlocked ? const Color(0xFFE5E7EB) : null),
              border: d == today && !selected && !inline ? Border.all(color: AppColors.neutral300) : null,
            ),
            child: Text(
              '$dayNum',
              style: AppText.inter(
                size: 14,
                weight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? Colors.white
                    : disabled
                        ? const Color(0xFF9CA3AF)
                        : inRange
                            ? AppColors.rangeText
                            : const Color(0xFF111827),
              ).copyWith(decoration: (isBlocked && !past) || (inline && disabled) ? TextDecoration.lineThrough : null),
            ),
          ),
        ]),
      ),
    );
  }
}
