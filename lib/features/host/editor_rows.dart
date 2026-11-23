import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'editor_fields.dart';

const _forest = AppColors.hostForest;

/// Compact labelled input used inside offer / discount / extra rows (label 12-13px bold).
class EditorSmallField extends StatefulWidget {
  const EditorSmallField({super.key, required this.label, required this.value, required this.onChanged, this.placeholder, this.error, this.keyboard, this.lines = 1, this.maxLength, this.labelSize = 12});
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? placeholder;
  final String? error;
  final TextInputType? keyboard;
  final int lines;
  final int? maxLength;
  final double labelSize;

  @override
  State<EditorSmallField> createState() => _EditorSmallFieldState();
}

class _EditorSmallFieldState extends State<EditorSmallField> {
  late final _c = TextEditingController(text: widget.value);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(EditorSmallField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _c.text != widget.value) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(widget.label, style: AppText.inter(size: widget.labelSize, weight: FontWeight.w700, color: _forest))),
        Container(
          constraints: const BoxConstraints(minHeight: 48),
          decoration: editorControlDecoration(error: widget.error, focused: _focus.hasFocus),
          child: TextField(
            controller: _c,
            focusNode: _focus,
            onChanged: widget.onChanged,
            minLines: widget.lines,
            maxLines: widget.lines,
            maxLength: widget.maxLength,
            keyboardType: widget.lines > 1 ? TextInputType.multiline : widget.keyboard,
            style: AppText.inter(size: 16, color: _forest),
            decoration: InputDecoration(
              counterText: '',
              hintText: widget.placeholder,
              hintStyle: AppText.inter(size: 16, color: AppColors.neutral400),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
        ),
        EditorFieldError(widget.error),
      ]);
}

/// Tappable date control (web `<input type="date">`); the value is an ISO yyyy-MM-dd string.
class EditorDateField extends StatelessWidget {
  const EditorDateField({super.key, required this.label, required this.value, required this.onChanged, this.error, this.min});
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? error;
  final String? min;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(label, style: AppText.inter(size: 13, weight: FontWeight.w700, color: _forest))),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final now = DateTime.now();
            final first = DateTime.tryParse(min ?? '') ?? DateTime(now.year - 1);
            final init = DateTime.tryParse(value) ?? (first.isAfter(now) ? first : now);
            final picked = await showDatePicker(context: context, initialDate: init.isBefore(first) ? first : init, firstDate: first, lastDate: DateTime(now.year + 5));
            if (picked != null) {
              onChanged('${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
            }
          },
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            decoration: editorControlDecoration(error: error),
            child: Row(children: [
              Expanded(child: Text(value.isEmpty ? 'yyyy-mm-dd' : value, style: AppText.inter(size: 16, color: value.isEmpty ? AppColors.neutral400 : _forest))),
              const Icon(Icons.calendar_today_outlined, size: 16, color: AppColors.neutral500),
            ]),
          ),
        ),
        EditorFieldError(error),
      ]);
}

/// Subtle trash button used on rows (grey icon).
class EditorTrashButton extends StatelessWidget {
  const EditorTrashButton({super.key, required this.onTap, this.size = 48, this.tooltip = ''});
  final VoidCallback onTap;
  final double size;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(width: size, height: size, child: const Icon(Icons.delete_outline, size: 18, color: AppColors.neutral400)),
        ),
      );
}

/// Underlined "+ Add ..." text button.
class EditorAddLink extends StatelessWidget {
  const EditorAddLink({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.add, size: 16, color: _forest),
              const SizedBox(width: 6),
              Flexible(child: Text(label, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest).copyWith(decoration: TextDecoration.underline, decorationColor: AppColors.neutral300))),
            ]),
          ),
        ),
      );
}

/// Rounded grey block holding one row of an offer / discount / extra.
class EditorRowBox extends StatelessWidget {
  const EditorRowBox({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.neutral50.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(12)),
        child: child,
      );
}

/// Parses typed text the way web `offerNumber` does: a number, or null while blank/unparsable.
num? editorParseNumber(String raw, {bool decimals = false}) {
  final text = raw.trim().replaceAll(',', '.');
  if (text.isEmpty) return null;
  if (decimals) return double.tryParse(text) ?? double.tryParse(RegExp(r'^[+-]?\d*\.?\d+').stringMatch(text) ?? '');
  final m = RegExp(r'^[+-]?\d+').stringMatch(text);
  return m == null ? null : int.tryParse(m);
}

String editorNumText(dynamic v) {
  if (v is num) return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  return '';
}
