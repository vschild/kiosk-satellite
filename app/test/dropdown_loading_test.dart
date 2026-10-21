import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/l10n/generated/ui_strings.dart';
import 'package:kiosk_satellite/ui/kit.dart';

void main() {
  Widget app(Widget child, {Locale locale = const Locale('en')}) =>
      MaterialApp(
        locale: locale,
        localizationsDelegates: UiStrings.localizationsDelegates,
        supportedLocales: UiStrings.supportedLocales,
        home: Scaffold(body: Material(child: child)),
      );

  DropdownRow<String> row({required bool loading}) => DropdownRow<String>(
    title: 'Wake word 1',
    description: 'The word that starts a voice command.',
    value: 'Okay Nabu',
    options: const [('Okay Nabu', 'Okay Nabu'), ('Hey Jarvis', 'Hey Jarvis')],
    onChanged: (_) {},
    loading: loading,
  );

  testWidgets('a loading dropdown shows a spinner and Loading, disabled', (
    tester,
  ) async {
    await tester.pumpWidget(app(row(loading: true)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading…'), findsOneWidget);
    expect(find.text('Okay Nabu'), findsNothing);
    final button = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(button.onChanged, isNull);
    expect(button.value, isNull);
    // A tap opens no menu.
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Hey Jarvis'), findsNothing);
  });

  testWidgets('a loaded dropdown shows its value and opens', (tester) async {
    await tester.pumpWidget(app(row(loading: false)));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Okay Nabu'), findsOneWidget);
    await tester.tap(find.text('Okay Nabu'));
    await tester.pumpAndSettle();
    expect(find.text('Hey Jarvis'), findsWidgets);
  });

  testWidgets('Loading follows the app language', (tester) async {
    await tester.pumpWidget(
      app(row(loading: true), locale: const Locale('es')),
    );
    expect(find.text('Loading…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
