// Sprint 10.0 smoke test.
//
// Verifies the OpenE2EE app shell boots without crashing and renders
// the Bilgilendirme (consent) screen first. The default counter test
// from `flutter create` is intentionally replaced — Sprint 9.6.8
// already removed the counter UI and the audit S20 baseline shape
// invariant requires that the test file remain valid Dart (i.e.
// references symbols that exist in lib/main.dart).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:opene2ee/main.dart';

void main() {
  testWidgets('App boots into Bilgilendirme (consent) screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenE2EEApp()));
    await tester.pumpAndSettle();

    // Bilgilendirme hero copy is present.
    expect(find.text('Bilgilendirme'), findsOneWidget);
    expect(find.text('AĞ GÜVENLİĞİ ARACI'), findsOneWidget);
    expect(find.text('Anladım, Devam Et'), findsOneWidget);
  });
}
