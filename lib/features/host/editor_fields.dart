import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Form primitives for the listing editor (host/listings/editor/EditorFields.js).

const _forest = AppColors.hostForest;

/// Server requirements that publishing needs; these get the red asterisk.
const editorRequiredFields = {
  'name', 'propertyType', 'description', 'street', 'city', 'country', 'phoneNumber', 'guests', 'bedrooms', 'beds', 'bathrooms',
  'amenities', 'photoUrls', 'nightlyPrice', 'minNights', 'checkIn', 'checkOut', 'availabilityConfirmed', 'payoutAcknowledged',
};

/// One GlobalKey per field name, so the editor can scroll to the first field with an error.
final Map<String, GlobalKey> editorFieldKeys = {};

/// Scrolls the field named [name] into view (no-op when it is not on screen).
void scrollToEditorField(String name) {
  final ctx = editorFieldKeys[name]?.currentContext;
  if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.1, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
}

BoxDecoration editorControlDecoration({String? error, bool focused = false}) => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: error != null ? const Color(0xFFF87171) : (focused ? _forest : AppColors.neutral300), width: focused ? 1.5 : 1),
    );

class EditorFieldError extends StatelessWidget {
  const EditorFieldError(this.message, {super.key});
  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null || message!.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.error_outline, size: 15, color: Color(0xFFDC2626))),
        const SizedBox(width: 6),
        Expanded(child: Text(message!, style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFFDC2626)))),
      ]),
    );
  }
}

class EditorLabel extends StatelessWidget {
  const EditorLabel(this.text, {super.key, this.required = false});
  final String text;
  final bool required;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: text, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
          if (required) TextSpan(text: ' *', style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFFDC2626))),
        ])),
      );
}

class EditorHint extends StatelessWidget {
  const EditorHint(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(text, style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.4)),
      );
}

/// StepIntro: grey helper paragraph at the top of a step.
class EditorIntro extends StatelessWidget {
  const EditorIntro(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: AppText.inter(size: 14, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.7));
}

/// Label + control + hint/error, the web `Field`.
class EditorField extends StatelessWidget {
  const EditorField({super.key, required this.name, required this.label, required this.child, this.hint, this.error});
  final String name;
  final String label;
  final Widget child;
  final String? hint;
  final String? error;

  @override
  Widget build(BuildContext context) => Column(key: editorFieldKeys.putIfAbsent(name, GlobalKey.new), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        EditorLabel(label, required: editorRequiredFields.contains(name)),
        child,
        if (hint != null && error == null) EditorHint(hint!),
        EditorFieldError(error),
      ]);
}

/// TextField / TextAreaField.
class EditorTextField extends StatefulWidget {
  const EditorTextField({
    super.key,
    required this.name,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
    this.error,
    this.placeholder,
    this.lines = 1,
    this.keyboard,
    this.autofill,
  });
  final String name;
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final String? error;
  final String? placeholder;
  final int lines;
  final TextInputType? keyboard;
  final Iterable<String>? autofill;

  @override
  State<EditorTextField> createState() => _EditorTextFieldState();
}

class _EditorTextFieldState extends State<EditorTextField> {
  late final _controller = TextEditingController(text: widget.value);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(EditorTextField old) {
    super.didUpdateWidget(old);
    // Outside edits (load, autosave round-trip) refresh the text; typing wins while focused.
    if (!_focus.hasFocus && _controller.text != widget.value) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EditorField(
        name: widget.name,
        label: widget.label,
        hint: widget.hint,
        error: widget.error,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          decoration: editorControlDecoration(error: widget.error, focused: _focus.hasFocus),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            onChanged: widget.onChanged,
            minLines: widget.lines,
            maxLines: widget.lines,
            keyboardType: widget.lines > 1 ? TextInputType.multiline : widget.keyboard,
            autofillHints: widget.autofill,
            style: AppText.inter(size: 16, color: _forest),
            decoration: InputDecoration(
              hintText: widget.placeholder,
              hintStyle: AppText.inter(size: 16, color: AppColors.neutral400),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              filled: false,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
        ),
      );
}

/// SelectField.
class EditorSelect extends StatelessWidget {
  const EditorSelect({super.key, required this.name, required this.label, required this.value, required this.options, required this.placeholder, required this.onChanged, this.hint, this.error});
  final String name;
  final String label;
  final String value;
  final List<(String, String)> options; // value, label
  final String placeholder;
  final ValueChanged<String> onChanged;
  final String? hint;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final known = options.any((o) => o.$1 == value);
    return EditorField(
      name: name,
      label: label,
      hint: hint,
      error: error,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: editorControlDecoration(error: error),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: known ? value : '',
            isExpanded: true,
            icon: const Icon(Icons.keyboard_arrow_down, size: 20, color: AppColors.neutral500),
            style: AppText.inter(size: 16, color: _forest),
            borderRadius: BorderRadius.circular(12),
            items: [
              DropdownMenuItem(value: '', child: Text(placeholder, style: AppText.inter(size: 16, color: _forest))),
              for (final o in options) DropdownMenuItem(value: o.$1, child: Text(o.$2, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => onChanged(v ?? ''),
          ),
        ),
      ),
    );
  }
}

/// NumberStepperField: 48px minus/plus around a numeric input that still accepts typing.
/// The parsed number (or '' while empty/unparsable) is written on every change.
class EditorNumberStepper extends StatefulWidget {
  const EditorNumberStepper({super.key, required this.name, required this.label, required this.value, required this.onValueChange, this.min = 0, this.error, this.step = 1, this.decimals = 0, this.prefix, this.suffix, this.hint});
  final String name;
  final String label;
  final dynamic value;
  final void Function(String name, dynamic value) onValueChange;
  final num min;
  final num step;
  final int decimals;
  final String? error;
  final String? prefix;
  final String? suffix;
  final String? hint;

  @override
  State<EditorNumberStepper> createState() => _EditorNumberStepperState();
}

class _EditorNumberStepperState extends State<EditorNumberStepper> {
  late final TextEditingController _text;
  final _focus = FocusNode();

  num? get _numeric => widget.value is num && (widget.value as num).isFinite ? widget.value as num : null;

  String _show(num? n) => n == null ? '0' : (n == n.roundToDouble() ? n.toInt().toString() : n.toString());

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: _show(_numeric));
    _focus.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(EditorNumberStepper old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _text.text != _show(_numeric)) _text.text = _show(_numeric);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  num _round(num n) => widget.decimals == 0 ? n.round() : num.parse(n.toStringAsFixed(widget.decimals));

  void _bump(num delta) {
    final base = _numeric ?? (widget.min - delta).clamp(0, double.infinity);
    final next = _round((base + delta) < widget.min ? widget.min : base + delta);
    _text.text = _show(next);
    widget.onValueChange(widget.name, next);
  }

  Widget _input({double pad = 12}) => TextField(
        controller: _text,
        focusNode: _focus,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.numberWithOptions(decimal: widget.decimals > 0),
        style: AppText.inter(size: 16, weight: FontWeight.w700, color: _forest),
        decoration: InputDecoration(border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false, isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: pad, vertical: 14)),
        onChanged: (raw) {
          setState(() {});
          final trimmed = raw.trim().replaceAll(',', '.');
          final parsed = trimmed.isEmpty ? null : num.tryParse(trimmed);
          widget.onValueChange(widget.name, parsed ?? '');
        },
      );

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    Widget button(IconData icon, VoidCallback? onTap) => InkWell(
          onTap: onTap,
          child: SizedBox(width: 48, child: Icon(icon, size: 20, color: onTap == null ? AppColors.neutral300 : _forest)),
        );
    return Column(key: editorFieldKeys.putIfAbsent(widget.name, GlobalKey.new), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EditorLabel(widget.label, required: editorRequiredFields.contains(widget.name)),
      Container(
        height: 48,
        clipBehavior: Clip.antiAlias,
        decoration: editorControlDecoration(error: widget.error, focused: focused),
        child: Row(children: [
          button(Icons.remove, (_numeric ?? 0) <= widget.min ? null : () => _bump(-widget.step)),
          Expanded(
            child: Container(
              decoration: const BoxDecoration(border: Border.symmetric(vertical: BorderSide(color: AppColors.neutral200))),
              child: Row(children: [
                if (widget.prefix != null) Padding(padding: const EdgeInsets.only(left: 12), child: Text(widget.prefix!, style: AppText.inter(size: 15, weight: FontWeight.w700, color: AppColors.neutral400))),
                if (widget.suffix == null)
                  Expanded(child: _input())
                else
                  Expanded(
                    child: Center(
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(width: (_text.text.isEmpty ? 1 : _text.text.length) * 10.0 + 6, child: _input(pad: 0)),
                        const SizedBox(width: 4),
                        Text(widget.suffix!, style: AppText.inter(size: 16, weight: FontWeight.w700, color: _forest)),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
          button(Icons.add, () => _bump(widget.step)),
        ]),
      ),
      if (widget.hint != null && widget.error == null) EditorHint(widget.hint!),
      EditorFieldError(widget.error),
    ]);
  }
}

/// grid-cols-1 gap-X sm:grid-cols-2
class EditorGrid extends StatelessWidget {
  const EditorGrid({super.key, required this.children, this.gap = 24});
  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final two = MediaQuery.sizeOf(context).width >= 640;
    if (!two) {
      return Column(children: [for (var i = 0; i < children.length; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : gap), child: SizedBox(width: double.infinity, child: children[i]))]);
    }
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      rows.add(Padding(
        padding: EdgeInsets.only(top: i == 0 ? 0 : gap),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: children[i]),
          SizedBox(width: gap),
          Expanded(child: i + 1 < children.length ? children[i + 1] : const SizedBox()),
        ]),
      ));
    }
    return Column(children: rows);
  }
}

/// space-y-N
class EditorStack extends StatelessWidget {
  const EditorStack({super.key, required this.children, this.gap = 24});
  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < children.length; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : gap), child: children[i]),
      ]);
}
