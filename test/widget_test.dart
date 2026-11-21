// UK Stay Hub smoke tests.
//
// The default Flutter "counter" test was left over from `flutter create` and
// tested a counter app that doesn't exist here. These tests cover real UK Stay Hub
// code without needing the network, the backend or Google Fonts downloads.
//
// Run with:  flutter test

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ukstayhub/core/api_client.dart';
import 'package:ukstayhub/core/format.dart';
import 'package:ukstayhub/core/i18n.dart';

void main() {
  group('Strings (translations)', () {
    final t = Strings({'Search': 'Find verified stays', 'Empty': ''});

    test('returns the translation for a known key', () {
      expect(t('Search'), 'Find verified stays');
    });

    test('falls back when the key is missing or empty', () {
      expect(t('Missing', 'Fallback'), 'Fallback');
      expect(t('Empty', 'Fallback'), 'Fallback');
      expect(t('Missing'), 'Missing');
    });

    test('the app is British English only', () {
      expect(t.pick('Ahoj', 'Hello'), 'Hello');
      expect(t.isEn, isTrue);
      expect(t.lang, 'en');
    });
  });

  group('money', () {
    test('formats pounds sterling', () {
      expect(money(120), '£120');
      expect(money(99.5), '£99.50');
      expect(moneyCents(1250), '£12.50');
    });
  });

  group('ApiException', () {
    test('401 is reported as unauthorized', () {
      final e = ApiException('Unauthorized', status: 401);
      expect(e.isUnauthorized, isTrue);
      expect(e.isNetwork, isFalse);
    });

    test('no status means a network problem', () {
      final e = ApiException('Network error');
      expect(e.isNetwork, isTrue);
      expect(e.toString(), 'Network error');
    });
  });

  testWidgets('translated text renders inside a ProviderScope', (tester) async {
    final t = Strings({'SearchAccommodation': 'Search stays'});

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {},
                child: Text(t('SearchAccommodation')),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Search stays'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });
}
