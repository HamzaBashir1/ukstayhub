import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/config.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import 'editor_fields.dart';

/// host/profile/HostProfilePage.js + hostProfileModel.js + HostProfilePhotoField.js.

const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;
const _displayMin = 2;
const _displayMax = 60;
const _aboutMax = 1000;
const _maxLanguages = 8;

// Native (endonym) labels; order matches the server's canonical order.
const _languages = [
  ('sk', 'Slovenčina'), ('cs', 'Čeština'), ('en', 'English'), ('de', 'Deutsch'), ('hu', 'Magyar'), ('pl', 'Polski'),
  ('uk', 'Українська'), ('it', 'Italiano'), ('fr', 'Français'), ('es', 'Español'), ('ru', 'Русский'), ('nl', 'Nederlands'),
];
// MUST match RESPONSE_TIMES in Controllers/HostProfileController.js exactly.
const _responseTimes = ['within_an_hour', 'within_a_day', 'within_a_few_days'];

String _responseLabel(String? v, Strings t) => switch (v) {
      'within_an_hour' => t.pick('Do hodiny', 'Within an hour'),
      'within_a_day' => t.pick('Do 24 hodín', 'Within a day'),
      'within_a_few_days' => t.pick('Do niekoľkých dní', 'Within a few days'),
      _ => t.pick('Neuvedené', 'Not stated'),
    };

class _Form {
  _Form({this.displayName = '', this.avatarUrl = '', this.about = '', List<String>? languages, this.responseTime = ''}) : languages = languages ?? [];
  String displayName;
  String avatarUrl;
  String about;
  List<String> languages;
  String responseTime;

  _Form copy() => _Form(displayName: displayName, avatarUrl: avatarUrl, about: about, languages: [...languages], responseTime: responseTime);

  factory _Form.from(Json p) => _Form(
        displayName: asString(p['displayName']),
        avatarUrl: asString(p['avatarUrl']),
        about: asString(p['about']),
        languages: [for (final l in _languages) if (asStringList(p['languages']).contains(l.$1)) l.$1],
        responseTime: _responseTimes.contains(asString(p['responseTime'])) ? asString(p['responseTime']) : '',
      );

  Json body() => {
        'displayName': displayName.replaceAll(RegExp(r'\s+'), ' ').trim(),
        'avatarUrl': avatarUrl.trim().isEmpty ? null : avatarUrl.trim(),
        'about': about.trim(),
        'languages': [for (final l in _languages) if (languages.contains(l.$1)) l.$1],
        'responseTime': responseTime.isEmpty ? null : responseTime,
      };
}

bool _isHttpUrl(String v) {
  if (v.isEmpty || RegExp(r'\s').hasMatch(v) || v.length > 2048) return false;
  final u = Uri.tryParse(v);
  return u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty;
}

bool _isManagedAvatar(String v) => RegExp(r'^/api/test-auth/host-profile-photo/[0-9a-f-]+/[0-9a-f-]+/avatar\.webp$').hasMatch(v);

String _fieldError(String field, String code, Strings t) => switch ('$field.$code') {
      'displayName.required' => t.pick('Zadajte meno, ktoré uvidia cestovatelia.', 'Enter the name travellers will see.'),
      'displayName.tooShort' => t.pick('Použite aspoň $_displayMin znaky.', 'Use at least $_displayMin characters.'),
      'displayName.tooLong' => t.pick('Maximálne $_displayMax znakov.', 'Keep it under $_displayMax characters.'),
      'avatarUrl.invalidUrl' => t.pick('Zadajte úplný odkaz na obrázok začínajúci https://.', 'Enter a full image link starting with https://.'),
      'about.tooLong' => t.pick('Predstavenie môže mať najviac $_aboutMax znakov.', 'Keep your introduction under $_aboutMax characters.'),
      'languages.tooMany' => t.pick('Vyberte najviac $_maxLanguages jazykov.', 'Choose up to $_maxLanguages languages.'),
      'languages.invalidChoice' => t.pick('Vyberte jazyky zo zoznamu.', 'Choose languages from the list.'),
      'responseTime.invalidChoice' => t.pick('Vyberte čas odpovede zo zoznamu.', 'Choose a response time from the list.'),
      _ => t.pick('Skontrolujte toto pole.', 'Check this field.'),
    };

Map<String, String> _validate(_Form f, Strings t) {
  final e = <String, String>{};
  final b = f.body();
  final name = asString(b['displayName']);
  if (name.isEmpty) {
    e['displayName'] = _fieldError('displayName', 'required', t);
  } else if (name.length < _displayMin) {
    e['displayName'] = _fieldError('displayName', 'tooShort', t);
  } else if (name.length > _displayMax) {
    e['displayName'] = _fieldError('displayName', 'tooLong', t);
  }
  final avatar = asStringOrNull(b['avatarUrl']);
  if (avatar != null && !_isHttpUrl(avatar) && !_isManagedAvatar(avatar)) e['avatarUrl'] = _fieldError('avatarUrl', 'invalidUrl', t);
  if (asString(b['about']).length > _aboutMax) e['about'] = _fieldError('about', 'tooLong', t);
  if (asList(b['languages']).length > _maxLanguages) e['languages'] = _fieldError('languages', 'tooMany', t);
  return e;
}

String _errorText(Object? e, Strings t) {
  final status = e is ApiException ? e.status : null;
  if (status == 401) return t.pick('Platnosť relácie vypršala. Prihláste sa znova.', 'Your session has expired. Log in again.');
  if (status == 403) return t.pick('Hostiteľský profil môžu upravovať len hostitelia.', 'Only hosts can edit a host profile.');
  if (status == 400) return t.pick('Niektoré polia treba opraviť.', 'Some fields need attention.');
  return t.pick('Skontrolujte pripojenie a skúste to znova.', 'Check your connection and try again.');
}

class HostProfileScreen extends ConsumerStatefulWidget {
  const HostProfileScreen({super.key});
  @override
  ConsumerState<HostProfileScreen> createState() => _HostProfileScreenState();
}

class _HostProfileScreenState extends ConsumerState<HostProfileScreen> {
  String _status = 'loading'; // loading | ready | error
  Object? _loadError;
  _Form _baseline = _Form();
  _Form _values = _Form();
  String? _savedAt;
  bool _attempted = false;
  Map<String, String> _serverErrors = {};
  String _phase = 'idle'; // idle | saving | saved | failed
  Object? _saveError;
  bool _photoBusy = false;
  String? _photoError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = 'loading');
    try {
      final p = await hostRepo.profile();
      if (!mounted) return;
      setState(() {
        _baseline = _Form.from(p);
        _values = _Form.from(p);
        _savedAt = asStringOrNull(p['savedAt']);
        _status = 'ready';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = e;
          _status = 'error';
        });
      }
    }
  }

  bool get _dirty => jsonEncode(_values.body()) != jsonEncode(_baseline.body());

  void _change(void Function(_Form f) mutate, {String? field}) {
    setState(() {
      mutate(_values);
      if (field != null) _serverErrors.remove(field);
      if (_phase == 'failed' || _phase == 'saved') _phase = 'idle';
    });
  }

  Future<void> _save() async {
    final t = ref.read(stringsProvider);
    if (_phase == 'saving' || _photoBusy) return;
    setState(() => _attempted = true);
    if (_validate(_values, t).isNotEmpty) {
      setState(() => _phase = 'failed');
      return;
    }
    if (_savedAt != null && !_dirty) {
      setState(() => _phase = 'saved');
      return;
    }
    setState(() {
      _serverErrors = {};
      _phase = 'saving';
      _saveError = null;
    });
    final sent = _values.copy();
    try {
      final p = await hostRepo.saveProfile(sent.body());
      if (!mounted) return;
      final form = _Form.from(p);
      setState(() {
        _baseline = form;
        // Keep whatever was typed since the request left; only the baseline moves.
        if (jsonEncode(_values.body()) == jsonEncode(sent.body())) _values = form.copy();
        _savedAt = asStringOrNull(p['savedAt']) ?? DateTime.now().toIso8601String();
        _phase = 'saved';
      });
    } catch (e) {
      if (!mounted) return;
      final errors = <String, String>{};
      if (e is ApiException && e.data is Map) {
        for (final item in asMapList(asMap(e.data)['errors'])) {
          final f = asString(item['field']);
          if (f.isNotEmpty && !errors.containsKey(f)) errors[f] = _fieldError(f, asString(item['code']), t);
        }
      }
      setState(() {
        _serverErrors = errors;
        _saveError = e;
        _phase = 'failed';
      });
    }
  }

  Future<void> _pickPhoto(ImageSource source) async {
    final t = ref.read(stringsProvider);
    final x = await ImagePicker().pickImage(source: source, imageQuality: 88, maxWidth: 1600, preferredCameraDevice: CameraDevice.front);
    if (x == null) return;
    final ext = x.name.split('.').last.toLowerCase();
    if (!const ['jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'].contains(ext)) {
      setState(() => _photoError = t.pick('Vyberte fotku JPEG, PNG, WebP alebo HEIC.', 'Choose a JPEG, PNG, WebP or HEIC photo.'));
      return;
    }
    if (await x.length() > 12 * 1024 * 1024) {
      setState(() => _photoError = t.pick('Vyberte fotku menšiu ako 12 MB.', 'Choose a photo smaller than 12 MB.'));
      return;
    }
    setState(() {
      _photoBusy = true;
      _photoError = null;
    });
    try {
      final r = await hostRepo.uploadProfilePhoto(File(x.path));
      final url = asStringOrNull(r['avatarUrl']);
      if (mounted && url != null) _change((f) => f.avatarUrl = url, field: 'avatarUrl');
    } catch (e) {
      final code = e is ApiException ? e.code : null;
      if (mounted) {
        setState(() => _photoError = code == 'unsupportedType'
            ? t.pick('Vyberte fotku JPEG, PNG, WebP alebo HEIC.', 'Choose a JPEG, PNG, WebP or HEIC photo.')
            : code == 'fileTooLarge'
                ? t.pick('Vyberte fotku menšiu ako 12 MB.', 'Choose a photo smaller than 12 MB.')
                : code == 'corruptImage'
                    ? t.pick('Táto fotka je poškodená alebo sa nedá prečítať.', 'This photo is damaged or cannot be read.')
                    : t.pick('Fotka sa nenahrala. Skontrolujte pripojenie a skúste to znova.', 'The photo was not uploaded. Check your connection and try again.'));
      }
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  String? _savedAtText(Strings t) {
    final d = DateTime.tryParse(_savedAt ?? '')?.toLocal();
    return d == null ? null : DateFormat('d MMM y, HH:mm', 'en_GB').format(d);
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 768;
    final sm = width >= 640;
    Widget page(Widget child) => ListView(padding: const EdgeInsets.only(bottom: 32), children: [Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 768), child: Padding(padding: EdgeInsets.symmetric(horizontal: wide ? 0 : 16), child: child)))]);

    if (_status == 'loading') {
      Widget box(double h) => Container(height: h, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200)));
      return page(Column(children: [Container(height: 32, width: 192, decoration: BoxDecoration(color: AppColors.neutral200, borderRadius: BorderRadius.circular(8))), const SizedBox(height: 16), box(112), const SizedBox(height: 16), box(256)]));
    }
    if (_status == 'error') {
      return page(Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFFECACA))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.error_outline, size: 22, color: Color(0xFFDC2626)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.pick('Nepodarilo sa načítať hostiteľský profil', "We couldn't load your host profile"), style: AppText.inter(size: 18, weight: FontWeight.w700, color: const Color(0xFFB91C1C))),
                const SizedBox(height: 4),
                Text(_errorText(_loadError, t), style: AppText.inter(size: 14, color: const Color(0xFFDC2626))),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(t.pick('Skúsiť znova', 'Retry'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFFB91C1C))),
            style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB91C1C), backgroundColor: Colors.white, side: const BorderSide(color: Color(0xFFFECACA)), minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 20), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ]),
      ));
    }

    final errors = {..._attempted ? _validate(_values, t) : <String, String>{}, ..._serverErrors};
    final saving = _phase == 'saving';
    final avatar = _values.avatarUrl.trim();
    final showAvatar = avatar.isNotEmpty && errors['avatarUrl'] == null;
    final initial = _values.displayName.trim().isEmpty ? 'H' : _values.displayName.trim()[0].toUpperCase();
    final savedAtText = _savedAtText(t);
    final dirty = _dirty;
    final selectedNames = [for (final l in _languages) if (_values.languages.contains(l.$1)) l.$2];

    Widget avatarCircle(double size, double fontSize) => Container(
          width: size,
          height: size,
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: _forest, shape: BoxShape.circle),
          child: showAvatar
              ? Image.network(avatar.startsWith('/') ? '${Uri.parse(AppConfig.apiBaseUrl).origin}$avatar' : avatar, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Text(initial, style: AppText.inter(size: fontSize, weight: FontWeight.w700, color: _gold)))
              : Text(initial, style: AppText.inter(size: fontSize, weight: FontWeight.w700, color: _gold)),
        );

    final preview = Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          avatarCircle(64, 24),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_values.displayName.trim().isEmpty ? t.pick('Vaše verejné meno', 'Your public name') : _values.displayName.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 18, weight: FontWeight.w700, color: _forest)),
              Text(selectedNames.isNotEmpty ? selectedNames.join(' · ') : t.pick('Jazyky neuvedené', 'Languages not stated'), style: AppText.inter(size: 14, color: AppColors.neutral500)),
              Text('${t.pick('Odpovedá', 'Replies')}: ${_responseLabel(_values.responseTime.isEmpty ? null : _values.responseTime, t).toLowerCase()}', style: AppText.inter(size: 14, color: AppColors.neutral500)),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.visibility_outlined, size: 15, color: AppColors.neutral500)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              savedAtText != null
                  ? t.pick('Uložené $savedAtText. Stránky ponúk zobrazia tento profil v ďalšej aktualizácii.', 'Saved $savedAtText. Listing pages will show this profile in a later update.')
                  : t.pick('Zatiaľ neuložené. Stránky ponúk zobrazia tento profil v ďalšej aktualizácii.', 'Not saved yet. Listing pages will show this profile in a later update.'),
              style: AppText.inter(size: 13, color: AppColors.neutral500, height: 1.45),
            ),
          ),
        ]),
      ]),
    );

    Widget photoField() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.pick('Profilová fotka', 'Profile photo'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
          const SizedBox(height: 4),
          Text(t.pick('Nepovinné. Odfotografujte sa alebo vyberte fotku zo zariadenia.', 'Optional. Take a photo or choose one from your device.'), style: AppText.inter(size: 13, color: AppColors.neutral500)),
          const SizedBox(height: 16),
          Wrap(spacing: 16, runSpacing: 16, crossAxisAlignment: WrapCrossAlignment.center, children: [
            avatarCircle(96, 30),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: saving || _photoBusy ? null : () => _pickPhoto(ImageSource.camera),
                icon: _photoBusy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.photo_camera_outlined, size: 17),
                label: Text(t.pick('Odfotiť sa', 'Take photo'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: Colors.white)),
                style: FilledButton.styleFrom(backgroundColor: _forest, foregroundColor: Colors.white, disabledBackgroundColor: _forest.withValues(alpha: 0.6), disabledForegroundColor: Colors.white, minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              ),
              OutlinedButton.icon(
                onPressed: saving || _photoBusy ? null : () => _pickPhoto(ImageSource.gallery),
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 17),
                label: Text(_values.avatarUrl.isNotEmpty ? t.pick('Nahradiť', 'Replace') : t.pick('Vybrať fotku', 'Choose photo'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
                style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: AppColors.neutral300), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              ),
              if (_values.avatarUrl.isNotEmpty)
                TextButton.icon(
                  onPressed: saving || _photoBusy ? null : () => _change((f) => f.avatarUrl = '', field: 'avatarUrl'),
                  icon: const Icon(Icons.delete_outline, size: 17),
                  label: Text(t.pick('Odstrániť', 'Remove'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: const Color(0xFFB91C1C))),
                  style: TextButton.styleFrom(foregroundColor: const Color(0xFFB91C1C), minimumSize: const Size(0, 44)),
                ),
            ]),
          ]),
          EditorFieldError(_photoError ?? errors['avatarUrl']),
        ]);

    Widget feedback() {
      if (_phase == 'saving') {
        return Row(mainAxisSize: MainAxisSize.min, children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 8), Text(t.pick('Profil sa ukladá…', 'Saving your profile…'), style: AppText.inter(size: 14, weight: FontWeight.w600, color: AppColors.neutral600))]);
      }
      if (_phase == 'failed') {
        final hasFieldErrors = errors.isNotEmpty;
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.error_outline, size: 16, color: Color(0xFFDC2626))),
          const SizedBox(width: 8),
          Expanded(child: Text(hasFieldErrors ? t.pick('Opravte označené polia a uložte znova.', 'Fix the highlighted fields, then save again.') : '${t.pick('Neuložené. ', 'Not saved. ')}${_errorText(_saveError, t)}', style: AppText.inter(size: 14, weight: FontWeight.w600, color: const Color(0xFFDC2626)))),
        ]);
      }
      if (_phase == 'saved' && !dirty) {
        return Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.check, size: 16, color: Color(0xFF047857)), const SizedBox(width: 8), Text('${t.pick('Uložené', 'Saved')}${savedAtText != null ? ' · $savedAtText' : ''}', style: AppText.inter(size: 14, weight: FontWeight.w600, color: const Color(0xFF047857)))]);
      }
      if (dirty) return Text(t.pick('Neuložené zmeny', 'Unsaved changes'), style: AppText.inter(size: 14, weight: FontWeight.w600, color: const Color(0xFFB45309)));
      return Text(savedAtText != null ? t.pick('Naposledy uložené $savedAtText', 'Last saved $savedAtText') : t.pick('Zatiaľ neuložené', 'Not saved yet'), style: AppText.inter(size: 14, color: AppColors.neutral500));
    }

    final saveButton = FilledButton.icon(
      onPressed: saving || _photoBusy ? null : _save,
      icon: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : (_phase == 'failed' && _saveError != null ? const Icon(Icons.refresh, size: 18) : const SizedBox.shrink()),
      label: Text(saving ? t.pick('Ukladá sa…', 'Saving…') : (_phase == 'failed' && _saveError != null ? t.pick('Skúsiť uložiť znova', 'Retry save') : t.pick('Uložiť profil', 'Save profile')), style: AppText.inter(size: 15, weight: FontWeight.w700, color: Colors.white)),
      style: FilledButton.styleFrom(backgroundColor: _forest, foregroundColor: Colors.white, disabledBackgroundColor: _forest.withValues(alpha: 0.6), disabledForegroundColor: Colors.white, minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    );

    final form = Container(
      padding: EdgeInsets.all(sm ? 28 : 20),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200), boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))]),
      child: EditorStack(children: [
        EditorTextField(
          name: 'displayName',
          label: t.pick('Verejné meno', 'Public name'),
          value: _values.displayName,
          error: errors['displayName'],
          hint: t.pick('Krstné meno alebo názov vášho miesta, napr. „Jana“ alebo „Chata Lúčky“.', 'First name or the name of your place, e.g. “Jana” or “Chata Lúčky”.'),
          autofill: const [AutofillHints.nickname],
          onChanged: (v) => _change((f) => f.displayName = v, field: 'displayName'),
        ),
        photoField(),
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EditorTextField(
            name: 'about',
            label: t.pick('O vás', 'About you'),
            value: _values.about,
            error: errors['about'],
            lines: 5,
            hint: t.pick('Nepovinné. Kto ste, čo môžu hostia očakávať a ako radi hostíte.', 'Optional. Who you are, what guests can expect, and how you like to host.'),
            onChanged: (v) => _change((f) => f.about = v, field: 'about'),
          ),
          const SizedBox(height: 4),
          Align(alignment: Alignment.centerRight, child: Text('${_values.about.length}/$_aboutMax', style: AppText.inter(size: 12, weight: FontWeight.w600, color: _values.about.length > _aboutMax ? const Color(0xFFDC2626) : AppColors.neutral400))),
        ]),
        EditorField(
          name: 'languages',
          label: t.pick('Jazyky, ktorými hovoríte', 'Languages you speak'),
          hint: t.pick('Nepovinné. Ťuknite na každý jazyk, v ktorom viete hostiť.', 'Optional. Tap every language you can host in.'),
          error: errors['languages'],
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final l in _languages)
              Builder(builder: (_) {
                final selected = _values.languages.contains(l.$1);
                return Material(
                  color: selected ? _forest : Colors.white,
                  shape: StadiumBorder(side: BorderSide(color: selected ? _forest : AppColors.neutral300)),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () => _change((f) => selected ? f.languages.remove(l.$1) : f.languages.add(l.$1), field: 'languages'),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (selected) ...[const Icon(Icons.check, size: 15, color: Colors.white), const SizedBox(width: 6)],
                        Text(l.$2, style: AppText.inter(size: 14, weight: FontWeight.w700, color: selected ? Colors.white : _forest)),
                      ]),
                    ),
                  ),
                );
              }),
          ]),
        ),
        EditorSelect(
          name: 'responseTime',
          label: t.pick('Ako rýchlo odpovedáte', 'How quickly you reply'),
          value: _values.responseTime,
          options: [for (final v in _responseTimes) (v, _responseLabel(v, t))],
          placeholder: _responseLabel(null, t),
          hint: t.pick('Nepovinné. Nastaví očakávania hostí; zatiaľ sa nemeria.', "Optional. Sets guests' expectations; it is not measured yet."),
          error: errors['responseTime'],
          onChanged: (v) => _change((f) => f.responseTime = v, field: 'responseTime'),
        ),
        Container(
          padding: const EdgeInsets.only(top: 20),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.neutral100))),
          child: sm
              ? Row(children: [Expanded(child: feedback()), const SizedBox(width: 12), saveButton])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [feedback(), const SizedBox(height: 12), saveButton]),
        ),
      ]),
    );

    final aside = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.neutral50, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.info_outline, size: 18, color: _forest)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.pick('Vaše meno, telefón, e-mail a heslo sú spoločné pre cestovanie aj hosťovanie. Upravíte ich vo svojom účte.', 'Your legal name, phone number, email and password are shared between travelling and hosting. Edit them in your account.'), style: AppText.inter(size: 14, color: AppColors.neutral600, height: 1.5)),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => context.go('/host/account'),
              child: SizedBox(
                height: 44,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.person_outline, size: 16, color: _forest),
                  const SizedBox(width: 8),
                  Text(t.pick('Otvoriť osobné údaje', 'Open personal details'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest).copyWith(decoration: TextDecoration.underline)),
                ]),
              ),
            ),
          ]),
        ),
      ]),
    );

    return PopScope(
      canPop: !dirty && !saving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Text(t.pick('Neuložené zmeny', 'Unsaved changes'), style: AppText.inter(size: 18, weight: FontWeight.w700, color: _forest)),
            content: Text(t.pick('Niektoré úpravy hostiteľského profilu ešte nie sú uložené. Pred odchodom ich uložte, alebo ich zahoďte.', "Some of your host profile edits haven't been saved yet. Save them before leaving, or discard them."), style: AppText.inter(size: 14, color: AppColors.neutral600, height: 1.6)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.pick('Zostať', 'Stay'))),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.pick('Zahodiť', 'Discard'), style: const TextStyle(color: Color(0xFFB91C1C)))),
            ],
          ),
        );
        if (leave == true && context.mounted) context.go('/host');
      },
      child: page(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.pick('Hostiteľský profil', 'Host profile'), style: AppText.inter(size: wide ? 30 : 24, weight: FontWeight.w700, color: _forest, height: 1.25)),
        const SizedBox(height: 4),
        Text(t.pick('Čo o vás ako hostiteľovi môžu vidieť cestovatelia.', 'What travellers may see about you as a host.'), style: AppText.inter(size: 15, color: AppColors.neutral500)),
        const SizedBox(height: 24),
        preview,
        const SizedBox(height: 24),
        form,
        const SizedBox(height: 24),
        aside,
      ])),
    );
  }
}
