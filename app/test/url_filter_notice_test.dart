import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/l10n/generated/ui_strings.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart';
import 'package:kiosk_satellite/ui/kiosk_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Page blocked notice follows Show blocked page notice.
void main() {
  Future<void> block(WidgetTester tester, {required bool notice}) async {
    SharedPreferences.setMockInitialValues({});
    final container = AppContainer();
    await container.settings.init();
    await container.settings.set(browserUrlFilterNotice, notice);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: UiStrings.localizationsDelegates,
        supportedLocales: UiStrings.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showUrlBlockedToast(context, container, 'History'),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('a blocked page shows the notice with the rule', (tester) async {
    await block(tester, notice: true);
    expect(find.text('Page blocked'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('with the switch off the notice stays away', (tester) async {
    await block(tester, notice: false);
    expect(find.text('Page blocked'), findsNothing);
  });
}
