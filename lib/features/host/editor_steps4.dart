import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';
import '../../core/i18n.dart';
import '../../core/json.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../state/auth.dart';
import '../../widgets/common.dart';
import 'editor_fields.dart';
import 'editor_rows.dart';
import 'stripe_onboarding.dart';

/// Availability & calendars and Payout Account steps (host/listings/editor/EditorSteps.js,
/// listings/PayoutAccountPicker.js).

const _forest = AppColors.hostForest;
const _gold = AppColors.hostGold;
const _teal = Color(0xFF319A81);

/// hostSetupAttention.js platformAnswer: true/false once answered, null while unanswered.
bool? platformAnswer(Json data) {
  final v = data['offeredOnOtherPlatforms'];
  if (v is bool) return v;
  return asList(data['calendarFeeds']).isNotEmpty ? true : null;
}

/// Large tappable checkbox card (web `CheckCard`).
class EditorCheckCard extends StatelessWidget {
  const EditorCheckCard({super.key, required this.name, required this.checked, required this.onChanged, required this.title, this.description, this.error});
  final String name;
  final bool checked;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? description;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final border = checked ? _gold : (error != null ? const Color(0xFFFCA5A5) : AppColors.neutral200);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => onChanged(!checked),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: checked ? _gold.withValues(alpha: 0.05) : Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: border, width: 2)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 24,
              height: 24,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(color: checked ? _gold : Colors.white, borderRadius: BorderRadius.circular(4), border: Border.all(color: checked ? _gold : AppColors.neutral300)),
              child: checked ? const Icon(Icons.check, size: 18, color: Colors.white) : null,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text.rich(TextSpan(children: [
                  TextSpan(text: title, style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest, height: 1.6)),
                  if (editorRequiredFields.contains(name)) TextSpan(text: ' *', style: AppText.inter(size: 15, weight: FontWeight.w700, color: const Color(0xFFDC2626))),
                ])),
                if (description != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(description!, style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.55))),
              ]),
            ),
          ]),
        ),
      ),
      EditorFieldError(error),
    ]);
  }
}

// ───────────────────────────── Availability & calendars ─────────────────────────────
Widget buildCalendarStep({required Json data, required Map<String, String> errors, required Strings t, required void Function(String, dynamic) set, required String? publishedId}) {
  return _CalendarStep(data: data, errors: errors, t: t, set: set, publishedId: publishedId);
}

class _CalendarStep extends StatelessWidget {
  const _CalendarStep({required this.data, required this.errors, required this.t, required this.set, required this.publishedId});
  final Json data;
  final Map<String, String> errors;
  final Strings t;
  final void Function(String, dynamic) set;
  final String? publishedId;

  Widget _notice({required IconData icon, required Color iconColor, required Color bg, required Color border, required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: border)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 18, color: iconColor)),
          const SizedBox(width: 12),
          Expanded(child: child),
        ]),
      );

  TextStyle get _small => AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral700, height: 1.55);

  @override
  Widget build(BuildContext context) {
    final feeds = asMapList(data['calendarFeeds']);
    final listedElsewhere = platformAnswer(data);
    final sm = MediaQuery.sizeOf(context).width >= 640;
    void updateFeed(int i, Json patch) => set('calendarFeeds', [for (var k = 0; k < feeds.length; k++) k == i ? {...feeds[k], ...patch} : feeds[k]]);

    Widget option(bool value, IconData icon, String title, String desc) {
      final selected = listedElsewhere == value;
      return InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => set('offeredOnOtherPlatforms', value),
        child: Container(
          constraints: const BoxConstraints(minHeight: 104),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFF8F4EA) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? _gold : AppColors.neutral200, width: 2),
            boxShadow: selected ? const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))] : null,
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: selected ? _forest : AppColors.neutral100, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, size: 20, color: selected ? Colors.white : AppColors.neutral500),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest, height: 1.45)),
                  const SizedBox(height: 4),
                  Text(desc, style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.5)),
                ]),
              ),
            ),
          ]),
        ),
      );
    }

    final options = [
      option(true, Icons.public, t.pick('Áno, aj na iných platformách', 'Yes, on other platforms too'), t.pick('Airbnb, Booking.com alebo iná stránka', 'Airbnb, Booking.com or another website')),
      option(false, Icons.calendar_today_outlined, t.pick('Nie, iba na Putku', 'No, only on UK Stay Hub'), t.pick('Všetky termíny spravujem priamo v Putku', 'I manage all dates directly in UK Stay Hub')),
    ];

    Widget guide(String name, String steps, String official, String video) => Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xB3F8F4EA), borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
            const SizedBox(height: 8),
            Text(steps, style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral600, height: 1.55)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => launchUrl(Uri.parse(official), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new, size: 14),
              label: Text(t.pick('Otvoriť oficiálny návod', 'Open official guide'), style: AppText.inter(color: Colors.white, size: 13, weight: FontWeight.w700)),
              style: FilledButton.styleFrom(backgroundColor: _forest, minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => launchUrl(Uri.parse(video), mode: LaunchMode.externalApplication),
              child: Container(
                constraints: const BoxConstraints(minHeight: 40),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(child: Text(t.pick('Doplnkové video na YouTube', 'Supplemental YouTube video'), style: AppText.inter(size: 13, weight: FontWeight.w600, color: AppColors.neutral600).copyWith(decoration: TextDecoration.underline, decorationColor: AppColors.neutral300))),
                  const SizedBox(width: 6),
                  const Icon(Icons.open_in_new, size: 14, color: AppColors.neutral600),
                ]),
              ),
            ),
          ]),
        );

    final guides = [
      guide('Airbnb', t.pick('Kalendár → Dostupnosť → Prepojiť kalendáre → Prepojiť s inou webovou stránkou. Skopírujte odkaz Airbnb kalendára.', 'Calendar → Availability → Connect calendars → Connect to another website. Copy the Airbnb calendar link.'), 'https://www.airbnb.com/help/article/99', 'https://www.youtube.com/watch?v=DyZgx_sq70c'),
      guide('Booking.com', t.pick('Extranet → Kalendár → Synchronizovať kalendáre → Pridať prepojenie → Preskočiť na export. Skopírujte exportný odkaz.', 'Extranet → Calendar → Sync calendars → Add calendar connection → Skip to export. Copy the export link.'), 'https://partner.booking.com/en-us/solutions/calendar-sync', 'https://www.youtube.com/watch?v=9DS5UPjtqig'),
    ];

    Widget feedCard(int index) {
      final feed = feeds[index];
      final urlError = errors['calendarFeeds.$index.url'];
      final label = EditorSmallField(label: t.pick('Platforma', 'Platform'), labelSize: 13, value: asString(feed['label']), placeholder: t.pick('napr. Airbnb', 'e.g. Airbnb'), onChanged: (v) => updateFeed(index, {'label': v}));
      final url = EditorSmallField(label: t.pick('Exportný iCal odkaz', 'Export iCal link'), labelSize: 13, value: asString(feed['url']), placeholder: 'https://…/calendar.ics', keyboard: TextInputType.url, error: urlError, onChanged: (v) => updateFeed(index, {'url': v}));
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral100, width: 2)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(t.pick('ODKAZ ${index + 1}', 'LINK ${index + 1}'), style: AppText.inter(size: 12, weight: FontWeight.w700, color: AppColors.neutral400, letterSpacing: 1.2))),
            EditorTrashButton(size: 40, onTap: () => set('calendarFeeds', [...feeds]..removeAt(index)), tooltip: t.pick('Odstrániť odkaz ${index + 1}', 'Remove link ${index + 1}')),
          ]),
          const SizedBox(height: 12),
          if (sm)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 1, child: label), const SizedBox(width: 16), Expanded(flex: 2, child: url)])
          else ...[label, const SizedBox(height: 16), url],
        ]),
      );
    }

    return EditorStack(gap: 32, children: [
      EditorIntro(t.pick('Udržujte dostupnosť aktuálnu a podľa potreby načítajte obsadené termíny z iných rezervačných platforiem.', 'Keep your availability accurate and, if needed, bring in blocked dates from other booking platforms.')),
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.pick('Ponúkate toto ubytovanie aj na iných platformách?', 'Do you list this property on other platforms?'), style: AppText.inter(size: 16, weight: FontWeight.w700, color: _forest)),
        if (listedElsewhere == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.error_outline, size: 15, color: Color(0xFFB91C1C))),
              const SizedBox(width: 8),
              Expanded(child: Text(t.pick('Vyberte, či ponúkate ubytovanie aj inde', 'Choose whether you offer this property elsewhere'), style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFFB91C1C)))),
            ]),
          ),
        Padding(padding: const EdgeInsets.only(top: 4), child: Text(t.pick('Odpoveď mení iba zobrazenie tejto časti. Žiadne uložené odkazy na kalendár sa nevymažú.', 'Your answer only changes what is shown here. It does not remove any saved calendar links.'), style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.55))),
        const SizedBox(height: 16),
        sm ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: options[0]), const SizedBox(width: 12), Expanded(child: options[1])]) : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [options[0], const SizedBox(height: 12), options[1]]),
      ]),
      if (listedElsewhere == false)
        _notice(
          icon: Icons.check_circle_outline,
          iconColor: _teal,
          bg: _teal.withValues(alpha: 0.05),
          border: _teal.withValues(alpha: 0.2),
          child: Text(
            feeds.isNotEmpty
                ? t.pick(
                    'Vaše uložené ${feeds.length == 1 ? 'prepojenie kalendára zostáva aktívne' : '${feeds.length} prepojenia kalendárov zostávajú aktívne'}. Ak ho chcete skontrolovať alebo odstrániť, vyberte vyššie „Áno“.',
                    'Your ${feeds.length} saved calendar ${feeds.length == 1 ? 'link remains' : 'links remain'} connected. Select “Yes” above to review or remove ${feeds.length == 1 ? 'it' : 'them'}.')
                : t.pick('Výborne. Termíny blokujte alebo otvárajte priamo v kalendári UK Stay Hub a aktualizujte ich pri každej zmene rezervácie.', 'Great. Block or open dates directly in your UK Stay Hub calendar and keep them up to date whenever a booking changes.'),
            style: _small,
          ),
        ),
      if (listedElsewhere == true)
        EditorStack(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.pick('Import obsadených termínov z iných platforiem', 'Import blocked dates from other platforms'), style: AppText.inter(size: 16, weight: FontWeight.w700, color: _forest)),
            const SizedBox(height: 4),
            Text(t.pick('Vložte exportný iCal odkaz (zvyčajne končí na .ics), aby sa rovnaké termíny nedali rezervovať dvakrát.', 'Paste an exported iCal link (usually ending in .ics) to prevent the same dates from being booked twice.'),
                style: AppText.inter(size: 13, weight: FontWeight.w500, color: AppColors.neutral500, height: 1.55)),
          ]),
          _notice(
            icon: Icons.refresh,
            iconColor: const Color(0xFFB45309),
            bg: const Color(0xB3FFFBEB),
            border: const Color(0xCCFDE68A),
            child: Text(t.pick('UK Stay Hub načíta platný odkaz po jeho uložení a potom pripojené kalendáre automaticky aktualizuje približne každé tri hodiny.', 'UK Stay Hub imports a valid link after you save it and then updates connected calendars automatically about every three hours.'),
                style: AppText.inter(size: 13, weight: FontWeight.w500, color: const Color(0xFF451A03), height: 1.55)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => set('calendarFeeds', [...feeds, {'label': '', 'url': ''}]),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(color: AppColors.neutral50.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.neutral300, width: 2)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.add, size: 18, color: _forest),
                  const SizedBox(width: 8),
                  Flexible(child: Text(t.pick('Pridať kalendár z inej platformy', 'Add calendar from another platform'), style: AppText.inter(size: 15, weight: FontWeight.w700, color: _forest))),
                ]),
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.neutral200)),
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding: EdgeInsets.all(sm ? 16 : 12),
                shape: const Border(),
                collapsedShape: const Border(),
                title: Text(t.pick('Ako získam iCal odkaz?', 'How do I get an iCal link?'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
                children: [sm ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: guides[0]), const SizedBox(width: 12), Expanded(child: guides[1])]) : Column(children: [guides[0], const SizedBox(height: 12), guides[1]])],
              ),
            ),
          ),
          for (var i = 0; i < feeds.length; i++) feedCard(i),
          EditorFieldError(errors['calendarFeeds']),
          if (publishedId == null && feeds.isNotEmpty)
            _notice(
              icon: Icons.calendar_today_outlined,
              iconColor: const Color(0xFFD97706),
              bg: const Color(0x80FFFBEB),
              border: const Color(0xFFFEF3C7),
              child: Text(t.pick('Tieto odkazy sa uložia s ponukou. Ich termíny sa importujú po jej zverejnení — vtedy ponuka získa vlastný kalendár.', 'These links are saved with the listing. Their dates are imported once you publish it — that is when the listing gets a calendar of its own.'),
                  style: AppText.inter(size: 13, weight: FontWeight.w500, color: const Color(0xFF92400E), height: 1.55)),
            ),
        ]),
      if (publishedId != null)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xFFF8F4EA), borderRadius: BorderRadius.circular(16), border: Border.all(color: _gold.withValues(alpha: 0.6))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.calendar_today_outlined, size: 18, color: _forest)),
              const SizedBox(width: 12),
              Expanded(child: Text(t.pick('Termíny, ktoré tieto odkazy importujú, sa zobrazia v kalendári tejto ponuky spolu s tými, ktoré blokujete sami.', "The dates these links import show up in this listing's calendar, alongside the ones you block yourself."), style: _small)),
            ]),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: () => context.go('/host/calendar?property=$publishedId'),
                style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: _forest), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: Text(t.pick('Otvoriť kalendár', 'Open calendar'), style: AppText.inter(size: 14, weight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      EditorCheckCard(
        name: 'availabilityConfirmed',
        checked: data['availabilityConfirmed'] == true,
        onChanged: (v) => set('availabilityConfirmed', v),
        error: errors['availabilityConfirmed'],
        title: t.pick('Potvrdzujem, že uvedená dostupnosť je aktuálna', 'I confirm the listed availability is up to date'),
        description: t.pick('Povinné pred zverejnením. Voľné termíny uvedené v kalendári je možné rezervovať a budem ich pravidelne aktualizovať.', 'Required before publishing. The open dates shown in the calendar can be booked, and I will keep them updated regularly.'),
      ),
    ]);
  }
}

// ───────────────────────────── Payout account ─────────────────────────────
final hostStripeAccountsProvider = FutureProvider.autoDispose<List<Json>>((ref) async {
  final id = ref.watch(authProvider).id;
  if (id.isEmpty) return const [];
  return hostRepo.stripeAccounts(id);
});

Json? effectivePayoutAccount(String? named, List<Json> accounts) {
  final available = accounts.where((a) => asString(a['accountId']).isNotEmpty && asString(a['status']) != 'disconnected').toList();
  return available.where((a) => asString(a['accountId']) == named).firstOrNull ?? available.where((a) => a['isDefault'] == true).firstOrNull ?? available.firstOrNull;
}

/// hostSetupAttention.js listingSetupAttention: the calendar answer is missing, or no payout account resolves.
/// [accounts] is null while the accounts are still loading (nothing is flagged then).
({bool calendar, bool readiness, bool verifying}) listingAttention(Json listing, List<Json>? accounts) {
  final data = listing['data'] is Map ? asMap(listing['data']) : listing;
  final account = accounts == null ? null : effectivePayoutAccount(asStringOrNull(data['payoutStripeAccountId']), accounts);
  return (
    calendar: platformAnswer(data) == null,
    readiness: accounts != null && account == null,
    verifying: accounts != null && account != null && !_accountReady(account),
  );
}

/// setupAttentionSummary: which top-level entries need attention.
({bool listings, bool payouts}) hostAttention(List<Json> listings, List<Json>? accounts) {
  final states = [for (final l in listings) listingAttention(l, accounts)];
  final noAccount = accounts != null && effectivePayoutAccount(null, accounts) == null;
  return (listings: states.any((s) => s.calendar || s.readiness), payouts: states.any((s) => s.readiness) || noAccount);
}

bool _accountReady(Json a) {
  final transfers = a['transfersActive'];
  return a['payoutsEnabled'] == true && (transfers == null ? a['chargesEnabled'] == true : transfers == true);
}

({String label, Color bg, Color fg, Color border}) _readiness(Json? account, Strings t) {
  if (account == null) return (label: t.pick('Nevybraté', 'Not selected'), bg: AppColors.neutral100, fg: AppColors.neutral600, border: AppColors.neutral200);
  if (_accountReady(account)) return (label: t.pick('Pripravené', 'Ready'), bg: const Color(0xFFF0FDF4), fg: const Color(0xFF15803D), border: const Color(0xFFBBF7D0));
  return (label: t.pick('Overuje sa', 'Verifying'), bg: const Color(0xFFFFFBEB), fg: const Color(0xFF92400E), border: const Color(0xFFFDE68A));
}

Widget buildReadinessStep({required Json data, required Map<String, String> errors, required Strings t, required void Function(String, dynamic) set, required Future<String?> Function() beforeConnect}) {
  return _ReadinessStep(data: data, errors: errors, t: t, set: set, beforeConnect: beforeConnect);
}

class _ReadinessStep extends ConsumerStatefulWidget {
  const _ReadinessStep({required this.data, required this.errors, required this.t, required this.set, required this.beforeConnect});
  final Json data;
  final Map<String, String> errors;
  final Strings t;
  final void Function(String, dynamic) set;
  final Future<String?> Function() beforeConnect;
  @override
  ConsumerState<_ReadinessStep> createState() => _ReadinessStepState();
}

class _ReadinessStepState extends ConsumerState<_ReadinessStep> {
  bool _connecting = false;
  String? _connectError;

  Future<void> _connectNew() async {
    final hostId = ref.read(authProvider).id;
    if (hostId.isEmpty) return;
    setState(() {
      _connectError = null;
      _connecting = true;
    });
    try {
      // Saves the draft first and returns the editor path to come back to.
      final returnTo = await widget.beforeConnect();
      if (returnTo == null) {
        if (mounted) setState(() => _connecting = false);
        return;
      }
      final url = await hostRepo.connectStripeAccount(hostId, returnTo);
      if (url.isEmpty) throw ApiException(widget.t.pick('Nepodarilo sa spustiť registráciu', 'Failed to start onboarding'));
      if (mounted) await openStripeOnboarding(context, url, returnTo: returnTo);
      if (mounted) setState(() => _connecting = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectError = errorText(e);
          _connecting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final data = widget.data;
    final sm = MediaQuery.sizeOf(context).width >= 640;
    final async = ref.watch(hostStripeAccountsProvider);
    final accounts = async.valueOrNull ?? const <Json>[];
    final loading = async.isLoading && !async.hasValue;
    final failed = async.hasError && !async.hasValue;
    final named = asStringOrNull(data['payoutStripeAccountId']);
    final selected = effectivePayoutAccount(named, accounts);
    final ready = !loading && !failed;
    final missing = ready && selected == null;
    final verifying = ready && selected != null && !_accountReady(selected);
    final state = _readiness(selected, t);
    final loadError = failed ? errorText(async.error!) : _connectError;

    Widget badge(String label, Color bg, Color fg, Color border) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6), border: Border.all(color: border)),
          child: Text(label, style: AppText.inter(size: 11, weight: FontWeight.w700, color: fg, height: 1.45)),
        );

    Widget accountTile(Json a) {
      final active = asString(a['accountId']) == asString(selected?['accountId']);
      final st = _readiness(a, t);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => widget.set('payoutStripeAccountId', asString(a['accountId'])),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: active ? _teal.withValues(alpha: 0.06) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: active ? _teal : AppColors.neutral200),
              boxShadow: active ? [const BoxShadow(color: _teal, spreadRadius: 0.5)] : null,
            ),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: active ? _teal : AppColors.neutral50, borderRadius: BorderRadius.circular(8), border: Border.all(color: active ? _teal : AppColors.neutral200)),
                child: Icon(Icons.account_balance_wallet_outlined, size: 16, color: active ? Colors.white : _teal),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.rich(TextSpan(children: [
                    TextSpan(text: asString(a['label']).isEmpty ? t.pick('Účet bez názvu', 'Unnamed account') : asString(a['label']), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
                    if (a['isDefault'] == true) TextSpan(text: '  ${t.pick('PREDVOLENÝ', 'DEFAULT')}', style: AppText.inter(size: 10, weight: FontWeight.w700, color: AppColors.neutral400, letterSpacing: 1)),
                  ])),
                  Text(asString(a['payoutIban']).isEmpty ? asString(a['accountId']) : asString(a['payoutIban']), style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral500)),
                ]),
              ),
              const SizedBox(width: 8),
              badge(st.label, st.bg, st.fg, st.border),
              if (active) ...[const SizedBox(width: 8), const Icon(Icons.check, size: 16, color: _teal)],
            ]),
          ),
        ),
      );
    }

    Widget label(String text) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(text.toUpperCase(), style: AppText.inter(size: 11, weight: FontWeight.w700, color: AppColors.neutral400, letterSpacing: 1.2)));

    final picker = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(t.pick('Výplatný účet', 'Payout account'), style: AppText.inter(size: 14, weight: FontWeight.w700, color: _forest)),
        if (ready) badge(verifying ? t.pick('Overenie prebieha', 'Verification in progress') : state.label, state.bg, state.fg, state.border),
      ]),
      if (missing) ...[
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(12)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.error_outline, size: 15, color: Color(0xFFB91C1C))),
            const SizedBox(width: 8),
            Expanded(child: Text(t.pick('Pripojte výplatný účet', 'Connect a payout account'), style: AppText.inter(size: 13, weight: FontWeight.w600, color: const Color(0xFFB91C1C)))),
          ]),
        ),
      ],
      if (named == null && selected != null && ready) ...[
        const SizedBox(height: 16),
        Text('${t.pick('Používa sa predvolený účet', 'Using the default account')}: ${asString(selected['label']).isEmpty ? asString(selected['accountId']) : asString(selected['label'])}', style: AppText.inter(size: 13, color: AppColors.neutral600)),
      ],
      const SizedBox(height: 16),
      Text(t.pick('Kam sa vyplácajú rezervácie tejto nehnuteľnosti. Môžete použiť jeden účet na všetko alebo iný pre každú nehnuteľnosť.', "Where this property's bookings are paid out. You can use one account for everything, or a different one per property."),
          style: AppText.inter(size: 13, color: AppColors.neutral500, height: 1.55)),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(color: _gold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12), border: Border.all(color: _gold.withValues(alpha: 0.3))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.error_outline, size: 16, color: Color(0xFF9A7A3A))),
          const SizedBox(width: 8),
          Expanded(child: Text(t.pick('Ponuku môžete dokončiť a uložiť už teraz — overenie môže prebehnúť neskôr. Zverejní sa, keď ho Stripe dokončí.', 'You can finish and save this listing now — verification can complete later. It publishes once Stripe is done.'), style: AppText.inter(size: 13, weight: FontWeight.w500, color: const Color(0xFF9A7A3A), height: 1.5))),
        ]),
      ),
      const SizedBox(height: 16),
      if (loading)
        Row(children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Text(t.pick('Načítavam účty…', 'Loading accounts…'), style: AppText.inter(size: 14, weight: FontWeight.w500, color: AppColors.neutral500)),
        ])
      else if (loadError != null)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFFECACA))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(loadError, style: AppText.inter(size: 14, weight: FontWeight.w500, color: const Color(0xFFB91C1C))),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                setState(() => _connectError = null);
                ref.invalidate(hostStripeAccountsProvider);
              },
              style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB91C1C), backgroundColor: Colors.white, side: const BorderSide(color: Color(0xFFFECACA)), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              child: Text(t.pick('Skúsiť znova', 'Try again'), style: AppText.inter(size: 13, weight: FontWeight.w700)),
            ),
          ]),
        )
      else ...[
        if (accounts.isNotEmpty) ...[label(t.pick('Použiť už pripojený účet', 'Use an account you already connected')), for (final a in accounts) accountTile(a), const SizedBox(height: 8)],
        if (accounts.isNotEmpty) label(t.pick('Alebo pripojiť ďalší', 'Or connect another')),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _connecting ? null : _connectNew,
            icon: _connecting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Icon(accounts.isNotEmpty ? Icons.add : Icons.open_in_new, size: 16),
            label: Text(
              _connecting ? t.pick('Otváram Stripe…', 'Opening Stripe…') : (accounts.isNotEmpty ? t.pick('Pripojiť ďalší Stripe účet', 'Connect another Stripe account') : t.pick('Pripojiť Stripe účet', 'Connect a Stripe account')),
              style: AppText.inter(color: Colors.white, size: 14, weight: FontWeight.w700),
            ),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF357965), minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 20), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ),
        const SizedBox(height: 8),
        Text(t.pick('Otvorí Stripe v prehliadači. Keď skončíte, vráťte sa do aplikácie a obnovte zoznam.', 'Opens Stripe in your browser. When you are done, come back to the app and refresh the list.'), style: AppText.inter(size: 12, weight: FontWeight.w500, color: AppColors.neutral400)),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => ref.invalidate(hostStripeAccountsProvider),
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(t.pick('Obnoviť účty', 'Refresh accounts'), style: AppText.inter(size: 13, weight: FontWeight.w700)),
            style: TextButton.styleFrom(foregroundColor: _forest, minimumSize: const Size(0, 44)),
          ),
        ),
      ],
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: () => context.go('/host/payouts'),
          style: OutlinedButton.styleFrom(foregroundColor: _forest, side: const BorderSide(color: _forest), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: Text(t.pick('Zobraziť stav výplat', 'View payout status'), style: AppText.inter(size: 14, weight: FontWeight.w700)),
        ),
      ),
    ]);

    return EditorStack(children: [
      Container(
        padding: EdgeInsets.all(sm ? 28 : 20),
        decoration: BoxDecoration(color: AppColors.neutral50.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(24), border: Border.all(color: AppColors.neutral200)),
        child: sm
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(width: 48, height: 48, decoration: BoxDecoration(color: _forest, borderRadius: BorderRadius.circular(16)), child: const Icon(Icons.account_balance_outlined, size: 24, color: Colors.white)),
                const SizedBox(width: 16),
                Expanded(child: picker),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(width: 48, height: 48, decoration: BoxDecoration(color: _forest, borderRadius: BorderRadius.circular(16)), child: const Icon(Icons.account_balance_outlined, size: 24, color: Colors.white)),
                const SizedBox(height: 16),
                picker,
              ]),
      ),
      EditorCheckCard(
        name: 'payoutAcknowledged',
        checked: data['payoutAcknowledged'] == true,
        onChanged: (v) => widget.set('payoutAcknowledged', v),
        error: widget.errors['payoutAcknowledged'],
        title: t.pick('Rozumiem, ako fungujú výplaty pri tejto ponuke', 'I understand how payouts work for this listing'),
        description: t.pick('Povinné pre dokončenie nastavenia. Rezervácie sa vyplácajú na vyššie zvolený účet, keď ho Stripe overí.', 'Required to finish setup. Bookings are paid out to the account selected above once Stripe has finished verifying it.'),
      ),
    ]);
  }
}
