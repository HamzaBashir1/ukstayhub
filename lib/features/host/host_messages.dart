import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/storage.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import 'host_shell.dart';

const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;
const _maxLength = 4000;
const _pollEvery = Duration(seconds: 15);

// ───────────────────────────── messagesModel.js ─────────────────────────────
String _loc(Strings t) => 'en_GB';

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// Time of day for today, weekday + time within the last week, otherwise a short date.
String formatMessageTime(String? iso, Strings t, DateTime now) {
  final date = DateTime.tryParse(iso ?? '')?.toLocal();
  if (date == null) return '';
  final time = DateFormat('HH:mm', _loc(t)).format(date);
  if (_sameDay(date, now)) return time;
  final ageDays = now.difference(date).inMilliseconds / 86400000;
  if (ageDays < 6 && ageDays > 0) return '${DateFormat('EEE', _loc(t)).format(date)} $time';
  return DateFormat(date.year == now.year ? 'd MMM' : 'd MMM y', _loc(t)).format(date);
}

String _dayLabel(String? iso, Strings t, DateTime now) {
  final date = DateTime.tryParse(iso ?? '')?.toLocal();
  if (date == null) return '';
  if (_sameDay(date, now)) return t.pick('Dnes', 'Today');
  if (_sameDay(date, now.subtract(const Duration(days: 1)))) return t.pick('Včera', 'Yesterday');
  return DateFormat('EEEE, d MMMM', _loc(t)).format(date);
}

String _shortRange(String a, String b, Strings t) {
  final s = DateTime.tryParse(a);
  final e = DateTime.tryParse(b);
  if (s == null || e == null) return '';
  final same = s.month == e.month && s.year == e.year;
  return '${DateFormat(same ? 'd' : 'd MMM', _loc(t)).format(s)} – ${DateFormat('d MMM', _loc(t)).format(e)}';
}

String _context(Json c, Strings t) {
  final name = asString(pick(c, 'listing.name'));
  final listing = [name.isEmpty ? t.pick('Ponuka bez názvu', 'Untitled listing') : name, asString(pick(c, 'reservation.unitName'))].where((e) => e.isNotEmpty).join(' · ');
  final a = asString(pick(c, 'reservation.checkIn'));
  final b = asString(pick(c, 'reservation.checkOut'));
  if (a.isEmpty || b.isEmpty) return listing;
  return '$listing · ${_shortRange(a, b, t)}';
}

String _messageError(Object? e, Strings t) {
  final code = e is ApiException ? e.code : null;
  switch (code) {
    case 'emptyMessage':
      return t.pick('Najprv napíšte správu.', 'Write a message first.');
    case 'messageTooLong':
      return t.pick('Správa je príliš dlhá (max. 4000 znakov).', 'The message is too long (max 4000 characters).');
    case 'forbidden':
      return t.pick('Nie ste účastníkom tejto konverzácie.', 'You are not a participant of this conversation.');
    case 'notFound':
      return t.pick('Táto konverzácia už neexistuje.', 'This conversation no longer exists.');
  }
  if (e is ApiException && e.status == 401) return t.pick('Platnosť relácie vypršala. Prihláste sa znova.', 'Your session has expired. Please log in again.');
  if (e is ApiException && e.isNetwork) return t.pick('Bez pripojenia. Skontrolujte sieť a skúste to znova.', 'No connection. Check your network and try again.');
  return t.pick('Niečo sa pokazilo. Skúste to znova.', 'Something went wrong. Please try again.');
}

String _deliveryLabel(String state, Strings t) => switch (state) {
      'sending' => t.pick('Odosiela sa…', 'Sending…'),
      'failed' => t.pick('Neodoslané', 'Not sent'),
      'read' => t.pick('Prečítané', 'Read'),
      _ => t.pick('Odoslané', 'Sent'),
    };

Widget _statePanel({required IconData icon, required String title, required String body, Widget? action, bool error = false}) => Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: error ? const Color(0xFFFEF2F2) : Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: error ? const Color(0xFFFECACA) : AppColors.neutral200),
        boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
      ),
      child: Column(children: [
        Container(width: 64, height: 64, decoration: BoxDecoration(color: _gold.withValues(alpha: 0.1), shape: BoxShape.circle), child: Icon(icon, size: 30, color: _gold)),
        const SizedBox(height: 20),
        Text(title, textAlign: TextAlign.center, style: AppText.inter(size: 20, weight: FontWeight.w700, color: error ? const Color(0xFFB91C1C) : _forest)),
        const SizedBox(height: 8),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 384), child: Text(body, textAlign: TextAlign.center, style: AppText.inter(size: 15, color: AppColors.neutral600, height: 1.6))),
        if (action != null) ...[const SizedBox(height: 24), action],
      ]),
    );

String _listingName(Json l, Strings t) {
  final a = asString(pick(l, 'data.name')).trim();
  if (a.isNotEmpty) return a;
  final b = asString(l['name']).trim();
  return b.isNotEmpty ? b : t.pick('Ponuka bez názvu', 'Unnamed listing');
}

// ───────────────────────────── Conversation list (MessagesPage.js) ─────────────────────────────
class HostMessagesScreen extends ConsumerStatefulWidget {
  const HostMessagesScreen({super.key});
  @override
  ConsumerState<HostMessagesScreen> createState() => _HostMessagesScreenState();
}

class _HostMessagesScreenState extends ConsumerState<HostMessagesScreen> {
  String? _property;
  bool _refreshing = false;

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    ref.invalidate(hostConversationsProvider);
    try {
      await ref.read(hostConversationsProvider.future);
    } catch (_) {} finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(hostConversationsProvider);
    final listings = ref.watch(hostListingsProvider).valueOrNull ?? const <Json>[];
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 768;
    final sm = width >= 640;
    final padX = wide ? 0.0 : 16.0;
    final all = async.valueOrNull;
    final loaded = all != null;
    final propertyKnown = _property == null || listings.isEmpty || listings.any((l) => asString(l['id']) == _property);
    final property = propertyKnown ? _property : null;
    final now = DateTime.now();
    final visible = ((all ?? const <Json>[]).where((c) => property == null || asString(c['accommodationId']) == property).toList())
      ..sort((a, b) => asString(b['lastMessageAt']).compareTo(asString(a['lastMessageAt'])));

    final titleBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t.pick('HOSTITEĽ', 'HOST'), style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral500, letterSpacing: 0.3)),
      Text(t.pick('Správy', 'Messages'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 24, weight: FontWeight.w700, color: _forest, height: 1.33)),
    ]);
    final select = listings.length > 1
        ? Container(
            height: 48,
            constraints: BoxConstraints(minWidth: sm ? 240 : 0),
            padding: const EdgeInsets.only(left: 16, right: 8),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral300)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: property,
                isExpanded: true,
                icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: AppColors.neutral500),
                style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest),
                borderRadius: BorderRadius.circular(12),
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text(t.pick('Všetky ubytovania', 'All properties'))),
                  for (final l in listings) DropdownMenuItem<String?>(value: asString(l['id']), child: Text(_listingName(l, t), overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _property = v),
              ),
            ),
          )
        : null;
    final refresh = loaded
        ? InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _refreshing ? null : _refresh,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral300)),
              child: _refreshing ? const Padding(padding: EdgeInsets.all(15), child: CircularProgressIndicator(strokeWidth: 2, color: _forest)) : const Icon(Icons.refresh, size: 18, color: _forest),
            ),
          )
        : null;
    final controls = Row(mainAxisSize: sm ? MainAxisSize.min : MainAxisSize.max, children: [
      if (select != null) sm ? select : Expanded(child: select),
      if (select != null && refresh != null) const SizedBox(width: 8),
      if (refresh != null) refresh,
    ]);
    final header = sm
        ? Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: titleBlock), controls])
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [titleBlock, if (select != null || refresh != null) ...[const SizedBox(height: 12), controls]]);

    Widget body;
    if (!loaded && async.isLoading) {
      body = Column(children: [for (var i = 0; i < 3; i++) Padding(padding: const EdgeInsets.only(bottom: 12), child: Container(height: 96, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200))))]);
    } else if (!loaded && async.hasError) {
      body = _statePanel(
        icon: Icons.error_outline,
        error: true,
        title: t.pick('Správy sa nepodarilo načítať', "We couldn't load your messages"),
        body: _messageError(async.error, t),
        action: OutlinedButton.icon(
          onPressed: () => ref.invalidate(hostConversationsProvider),
          icon: const Icon(Icons.refresh, size: 16),
          label: Text(t.pick('Skúsiť znova', 'Retry'), style: AppText.inter(size: 15, weight: FontWeight.w700)),
          style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB91C1C), backgroundColor: Colors.white, side: const BorderSide(color: Color(0xFFFECACA)), minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        ),
      );
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!propertyKnown) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFDE68A))),
            child: Text(t.pick('Toto ubytovanie už nie je medzi vašimi ponukami, zobrazujú sa všetky.', 'That property is no longer in your listings, so all properties are shown.'), style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFF92400E))),
          ),
          const SizedBox(height: 12),
        ],
        if (async.hasError) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFECACA))),
            child: Row(children: [
              const Icon(Icons.error_outline, size: 16, color: Color(0xFFB91C1C)),
              const SizedBox(width: 8),
              Expanded(child: Text('${t.pick('Nepodarilo sa obnoviť: ', "Couldn't refresh: ")}${_messageError(async.error, t)}', style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFFB91C1C)))),
            ]),
          ),
          const SizedBox(height: 12),
        ],
        if (visible.isEmpty)
          _statePanel(
            icon: Icons.forum_outlined,
            title: property != null ? t.pick('Pre toto ubytovanie žiadne správy', 'No messages for this property') : t.pick('Zatiaľ žiadne správy', 'No messages yet'),
            body: listings.isEmpty ? t.pick('Keď zverejníte ponuku, hostia vám sem môžu písať.', 'Once you publish a listing, guests can write to you here.') : t.pick('Otázky hostí k vašim ponukám a pobytom sa zobrazia tu.', 'Questions from guests about your listings and stays will show up here.'),
          )
        else ...[
          for (final c in visible) Padding(padding: const EdgeInsets.only(bottom: 12), child: _ConversationCard(c: c, now: now)),
          const SizedBox(height: 4),
          Text(t.pick('Nové správy sa zobrazia po otvorení vlákna alebo obnovení.', 'New messages appear when you open a thread or refresh.'), textAlign: TextAlign.center, style: AppText.inter(size: 12, color: AppColors.neutral500)),
        ],
      ]);
    }

    return RefreshIndicator(
      color: _forest,
      onRefresh: () => ref.refresh(hostConversationsProvider.future),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 896),
              child: Padding(padding: EdgeInsets.symmetric(horizontal: padX), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, const SizedBox(height: 16), body])),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationCard extends ConsumerWidget {
  const _ConversationCard({required this.c, required this.now});
  final Json c;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final unreadCount = asInt(c['unreadCount']);
    final unread = unreadCount > 0;
    final last = asMap(c['lastMessage']);
    final preview = last.isEmpty ? '' : '${last['mine'] == true ? t.pick('Vy: ', 'You: ') : ''}${asString(last['body'])}';

    return Material(
      color: Colors.white,
      elevation: 0.5,
      shadowColor: const Color(0x0D000000),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.go('/host/messages/${asString(c['id'])}'),
        child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: unread ? _forest.withValues(alpha: 0.3) : AppColors.neutral200)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (unread) Container(width: 4, color: _forest),
                Expanded(
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 72),
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Expanded(child: Text(asString(pick(c, 'guest.name')), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 15, weight: unread ? FontWeight.w800 : FontWeight.w700, color: _forest))),
                            const SizedBox(width: 8),
                            Text(formatMessageTime(asStringOrNull(c['lastMessageAt']), t, now), style: AppText.inter(size: 12, color: AppColors.neutral500)),
                          ]),
                          const SizedBox(height: 2),
                          Text(_context(c, t), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 13, color: AppColors.neutral500)),
                          if (preview.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 14, weight: unread ? FontWeight.w600 : FontWeight.w400, color: unread ? _forest : AppColors.neutral600, height: 1.35)),
                          ],
                        ]),
                      ),
                      const SizedBox(width: 12),
                      if (unread)
                        Container(
                          constraints: const BoxConstraints(minWidth: 24),
                          height: 24,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: _forest, borderRadius: BorderRadius.circular(12)),
                          child: Text('$unreadCount', style: AppText.inter(size: 12, weight: FontWeight.w700, color: Colors.white, height: 1)),
                        )
                      else
                        const Icon(Icons.chevron_right, size: 20, color: AppColors.neutral400),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── Conversation (ConversationPage.js) ─────────────────────────────
class _OutboxEntry {
  _OutboxEntry({required this.clientKey, required this.body, required this.createdAt});
  final String clientKey;
  final String body;
  final String createdAt;
  String status = 'sending'; // sending | failed
  bool permanent = false;
  Object? error;
}

class HostConversationScreen extends ConsumerStatefulWidget {
  const HostConversationScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<HostConversationScreen> createState() => _HostConversationScreenState();
}

class _HostConversationScreenState extends ConsumerState<HostConversationScreen> {
  Json? _conv;
  List<Json> _messages = [];
  final List<_OutboxEntry> _outbox = [];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _poll;
  String _phase = 'loading'; // loading | ready | forbidden | notFound | error
  Object? _loadError;
  bool _pollFailed = false;
  String? _markedFor;

  String get _outboxKey => 'hostOutbox:${widget.id}';

  /// Unsent text survives leaving the screen and restarting the app: whatever was still sending is restored as "Not sent".
  void _restoreOutbox() {
    try {
      final raw = Prefs.getString(_outboxKey);
      if (raw == null) return;
      for (final e in asMapList(jsonDecode(raw))) {
        final body = asString(e['body']);
        if (asString(e['clientKey']).isEmpty || body.trim().isEmpty) continue;
        final entry = _OutboxEntry(clientKey: asString(e['clientKey']), body: body, createdAt: asString(e['createdAt'], DateTime.now().toIso8601String()))
          ..status = 'failed'
          ..permanent = e['permanent'] == true;
        final err = asMap(e['error']);
        if (err.isNotEmpty) entry.error = ApiException(asString(err['message']), status: err['status'] is int ? err['status'] as int : null, code: asStringOrNull(err['code']));
        _outbox.add(entry);
      }
    } catch (_) {
      // A malformed store is dropped rather than trusted.
    }
  }

  void _persistOutbox() {
    if (_outbox.isEmpty) {
      Prefs.remove(_outboxKey);
      return;
    }
    Prefs.putString(
      _outboxKey,
      jsonEncode([
        for (final o in _outbox)
          {
            'clientKey': o.clientKey,
            'body': o.body,
            'createdAt': o.createdAt,
            'permanent': o.permanent,
            if (o.error is ApiException) 'error': {'message': (o.error as ApiException).message, 'status': (o.error as ApiException).status, 'code': (o.error as ApiException).code},
          },
      ]),
    );
  }

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() {}));
    _restoreOutbox();
    _load();
    _poll = Timer.periodic(_pollEvery, (_) {
      if (_phase == 'ready') _load(poll: true);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool poll = false}) async {
    if (!poll && _conv == null) setState(() => _phase = 'loading');
    try {
      final c = await hostRepo.conversation(widget.id);
      if (!mounted) return;
      final msgs = asMapList(c['messages']);
      final known = {for (final m in msgs) asString(m['clientKey'])};
      final grew = msgs.length != _messages.length;
      setState(() {
        _conv = c;
        _messages = msgs;
        _phase = 'ready';
        _pollFailed = false;
        // A retry that did reach the server is already stored: drop the local copy.
        _outbox.removeWhere((o) => known.contains(o.clientKey));
      });
      _persistOutbox();
      if (grew) _toBottom();
      _markRead(c);
    } catch (e) {
      if (!mounted) return;
      final status = e is ApiException ? e.status : null;
      if (_conv != null) {
        setState(() => _pollFailed = true);
      } else {
        setState(() {
          _loadError = e;
          _phase = status == 403 ? 'forbidden' : (status == 404 ? 'notFound' : 'error');
        });
      }
    }
  }

  void _markRead(Json c) {
    if (asInt(c['unreadCount']) <= 0) return;
    final at = asString(c['lastMessageAt']);
    if (_markedFor == at) return;
    _markedFor = at;
    hostRepo.markRead(widget.id).then((_) {
      ref.invalidate(hostDashboardProvider);
      ref.invalidate(hostConversationsProvider);
    }).catchError((Object e) {
      final status = e is ApiException ? e.status : null;
      if (status != 403 && status != 404) _markedFor = null; // retried on the next poll
    });
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });

  String _newKey() => 'msg_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}_${(DateTime.now().microsecondsSinceEpoch * 7919).toRadixString(36)}';

  Future<void> _deliver(_OutboxEntry entry) async {
    setState(() {
      entry.status = 'sending';
      entry.error = null;
    });
    _persistOutbox();
    try {
      await hostRepo.sendMessage(widget.id, entry.body, entry.clientKey);
      if (!mounted) return;
      await _load(poll: true);
      ref.invalidate(hostConversationsProvider);
    } catch (e) {
      if (!mounted) return;
      final status = e is ApiException ? e.status : null;
      setState(() {
        entry.status = 'failed';
        entry.error = e;
        entry.permanent = status == 400 || status == 403 || status == 404;
      });
      _persistOutbox();
    }
  }

  void _submit() {
    final text = _input.text;
    if (text.trim().isEmpty || text.length > _maxLength) return;
    _input.clear();
    // The text now lives in the outbox: a failure shows as a "Not sent" bubble, so the composer is never touched afterwards.
    final entry = _OutboxEntry(clientKey: _newKey(), body: text, createdAt: DateTime.now().toIso8601String());
    setState(() => _outbox.add(entry));
    _persistOutbox();
    _toBottom();
    _deliver(entry);
  }

  /// Take a failed message back into the composer, after any newer text.
  void _edit(_OutboxEntry e) {
    setState(() => _outbox.remove(e));
    _persistOutbox();
    final current = _input.text;
    _input.text = current.trim().isEmpty ? e.body : '${current.replaceAll(RegExp(r'\s+$'), '')}\n${e.body}';
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 768;
    final padX = wide ? 0.0 : 16.0;

    Widget back() => InkWell(
          onTap: () => context.go('/host/messages'),
          child: SizedBox(
            height: 44,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.arrow_back, size: 18, color: _forest),
              const SizedBox(width: 6),
              Text(t.pick('Správy', 'Messages'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
            ]),
          ),
        );
    Widget page(Widget child) => ListView(padding: const EdgeInsets.only(bottom: 32), children: [Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 768), child: Padding(padding: EdgeInsets.symmetric(horizontal: padX), child: child)))]);

    if (_phase == 'loading') {
      return page(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Align(alignment: Alignment.centerLeft, child: back()),
        const SizedBox(height: 12),
        Container(height: 32, width: 200, decoration: BoxDecoration(color: AppColors.neutral200, borderRadius: BorderRadius.circular(12))),
        const SizedBox(height: 12),
        Container(height: 16, width: 260, decoration: BoxDecoration(color: AppColors.neutral200, borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 24),
        Container(height: 64, width: 280, decoration: BoxDecoration(color: AppColors.neutral200, borderRadius: BorderRadius.circular(16))),
      ]));
    }
    if (_phase != 'ready') {
      final (icon, title, body) = switch (_phase) {
        'forbidden' => (Icons.lock_outline, t.pick('Táto konverzácia nie je vaša', "This conversation isn't yours"), t.pick('Čítať ju môže len hosť a hostiteľ ponuky.', 'Only the guest and the host of the listing can read it.')),
        'notFound' => (Icons.forum_outlined, t.pick('Konverzácia sa nenašla', 'Conversation not found'), t.pick('Možno bola odstránená.', 'It may have been removed.')),
        _ => (Icons.error_outline, t.pick('Konverzáciu sa nepodarilo načítať', "We couldn't load this conversation"), _messageError(_loadError, t)),
      };
      return page(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(alignment: Alignment.centerLeft, child: back()),
        const SizedBox(height: 12),
        _statePanel(
          icon: icon,
          title: title,
          body: body,
          error: _phase == 'error',
          action: _phase == 'error'
              ? OutlinedButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(t.pick('Skúsiť znova', 'Retry'), style: AppText.inter(size: 15, weight: FontWeight.w700)),
                  style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB91C1C), backgroundColor: Colors.white, side: const BorderSide(color: Color(0xFFFECACA)), minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                )
              : FilledButton(
                  onPressed: () => context.go('/host/messages'),
                  style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  child: Text(t.pick('Späť na správy', 'Back to messages'), style: AppText.inter(color: Colors.white, size: 15, weight: FontWeight.w700)),
                ),
        ),
      ]));
    }

    final c = _conv!;
    final reservationId = asString(pick(c, 'reservation.id'));
    final accommodationId = asString(c['accommodationId']);
    final guest = asString(pick(c, 'guest.name'));
    final now = DateTime.now();

    // Stored messages first, then local outbox entries the server has not confirmed.
    final merged = <Json>[
      ..._messages,
      for (final o in _outbox) {'id': 'local:${o.clientKey}', 'senderRole': 'host', 'body': o.body, 'createdAt': o.createdAt, 'state': o.status, 'local': true, 'entry': o},
    ];
    final groups = <(String, String, List<Json>)>[];
    for (final m in merged) {
      final d = DateTime.tryParse(asString(m['createdAt']))?.toLocal();
      final key = d == null ? 'unknown' : '${d.year}-${d.month}-${d.day}';
      if (groups.isNotEmpty && groups.last.$1 == key) {
        groups.last.$3.add(m);
      } else {
        groups.add((key, _dayLabel(asString(m['createdAt']), t, now), [m]));
      }
    }

    Widget pillButton(String label, IconData icon, VoidCallback onTap, {bool primary = false}) => InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: primary ? _forest : Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: primary ? _forest : AppColors.neutral300)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 15, color: primary ? Colors.white : _forest),
              const SizedBox(width: 6),
              Text(label, style: AppText.inter(size: 13, weight: FontWeight.w700, color: primary ? Colors.white : _forest)),
            ]),
          ),
        );

    Widget bubble(Json m) {
      final mine = asString(m['senderRole']) == 'host';
      final o = m['entry'] as _OutboxEntry?;
      final state = o != null ? o.status : (asString(m['state']).isEmpty ? 'sent' : asString(m['state']));
      final failed = state == 'failed';
      final permanent = failed && (o?.permanent ?? false);
      final time = formatMessageTime(asStringOrNull(m['createdAt']), t, now);
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: (width >= 768 ? 768 : width) * (wide ? 0.7 : 0.85)),
          child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
            Opacity(
              opacity: state == 'sending' ? 0.7 : 1,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: mine ? (failed ? const Color(0xFFFEF2F2) : _forest) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: mine ? (failed ? Border.all(color: const Color(0xFFFECACA)) : null) : Border.all(color: AppColors.neutral200),
                ),
                child: Text(asString(m['body']), style: AppText.inter(size: 15, color: mine && !failed ? Colors.white : _forest, height: 1.6)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (mine) ...[
                  state == 'sending'
                      ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
                      : Icon(failed ? Icons.error_outline : (state == 'read' ? Icons.done_all : Icons.check), size: 12, color: failed ? const Color(0xFFDC2626) : AppColors.neutral500),
                  const SizedBox(width: 4),
                ],
                Text(mine ? _deliveryLabel(state, t) : time, style: AppText.inter(size: 11, weight: failed ? FontWeight.w600 : FontWeight.w400, color: failed ? const Color(0xFFDC2626) : AppColors.neutral500)),
                if (mine && state != 'sending' && !failed) Text(' · $time', style: AppText.inter(size: 11, color: AppColors.neutral500)),
              ]),
            ),
            if (failed && o != null) ...[
              const SizedBox(height: 4),
              if (o.error != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(_messageError(o.error, t), textAlign: TextAlign.right, style: AppText.inter(size: 12, color: const Color(0xFFDC2626)))),
              Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: [
                if (!permanent) pillButton(t.pick('Skúsiť znova', 'Retry'), Icons.replay, () => _deliver(o), primary: true),
                pillButton(t.pick('Upraviť', 'Edit'), Icons.edit_outlined, () => _edit(o), primary: permanent),
                if (permanent) pillButton(t.pick('Odstrániť', 'Delete'), Icons.delete_outline, () {
                  setState(() => _outbox.remove(o));
                  _persistOutbox();
                }),
              ]),
            ],
          ]),
        ),
      );
    }

    final canSend = _input.text.trim().isNotEmpty && _input.text.length <= _maxLength;
    final len = _input.text.length;

    return Column(children: [
      Expanded(
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 768),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: padX),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Align(alignment: Alignment.centerLeft, child: back()),
                    const SizedBox(height: 4),
                    Text(guest, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 24, weight: FontWeight.w700, color: _forest, height: 1.33)),
                    Text(_context(c, t), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.inter(size: 14, color: AppColors.neutral600)),
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      if (reservationId.isNotEmpty)
                        pillButton(t.pick('Otvoriť rezerváciu', 'Open reservation'), Icons.assignment_outlined, () => context.go('/host/reservations/$reservationId'))
                      else
                        pillButton(t.pick('Otvoriť ponuku', 'Open listing'), Icons.house_outlined, () => context.go('/host/listings/$accommodationId')),
                      pillButton(t.pick('Kalendár', 'Calendar'), Icons.calendar_today_outlined, () => context.go('/host/calendar?property=$accommodationId')),
                    ]),
                    const SizedBox(height: 12),
                    if (_pollFailed) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFDE68A))),
                        child: Row(children: [
                          const Icon(Icons.error_outline, size: 16, color: Color(0xFF92400E)),
                          const SizedBox(width: 8),
                          Expanded(child: Text(t.pick('Nepodarilo sa skontrolovať nové správy. Skúšame to automaticky.', "Couldn't check for new messages. Retrying automatically."), style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFF92400E)))),
                        ]),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (merged.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral300)),
                        child: Text(t.pick('Zatiaľ žiadne správy. Pozdravte hosťa!', 'No messages yet. Say hello!'), textAlign: TextAlign.center, style: AppText.inter(size: 14, color: AppColors.neutral500)),
                      )
                    else
                      for (final g in groups)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(g.$2.toUpperCase(), textAlign: TextAlign.center, style: AppText.inter(size: 11, weight: FontWeight.w700, color: AppColors.neutral400, letterSpacing: 0.3))),
                            for (final m in g.$3) Padding(padding: const EdgeInsets.only(bottom: 8), child: bubble(m)),
                          ]),
                        ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(t.pick('Nové správy sa kontrolujú každých 15 s, kým je vlákno otvorené.', 'Checks for new messages every 15 s while open.'), textAlign: TextAlign.center, style: AppText.inter(size: 11, color: AppColors.neutral400)),
                    ),
                  ]),
                ),
              ),
            ),
          ],
        ),
      ),
      Container(
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.95), border: const Border(top: BorderSide(color: AppColors.neutral200))),
        child: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 768),
              child: Padding(
                padding: EdgeInsets.fromLTRB(wide ? 0 : 16, 12, wide ? 0 : 16, 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 48, maxHeight: 160),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral300)),
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 6,
                          maxLength: _maxLength + 500,
                          textCapitalization: TextCapitalization.sentences,
                          style: AppText.inter(size: 15, color: _forest),
                          decoration: InputDecoration(
                            counterText: '',
                            hintText: t.pick('Napíšte hosťovi $guest', 'Message $guest').trim(),
                            hintStyle: AppText.inter(size: 15, color: AppColors.neutral400),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Material(
                      color: canSend ? _forest : AppColors.neutral300,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: canSend ? _submit : null,
                        child: const SizedBox(width: 48, height: 48, child: Icon(Icons.send_rounded, size: 20, color: Colors.white)),
                      ),
                    ),
                  ]),
                  if (len > _maxLength - 500)
                    Padding(padding: const EdgeInsets.only(top: 8), child: Align(alignment: Alignment.centerRight, child: Text('$len / $_maxLength', style: AppText.inter(size: 11, weight: len > _maxLength ? FontWeight.w700 : FontWeight.w400, color: len > _maxLength ? const Color(0xFFDC2626) : AppColors.neutral500)))),
                ]),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
