import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A plugin screensaver's settings live on its Plugin Manager page, so the
/// Screensaver page links there above Widgets, where the stock modes link to
/// their own pages. Mirrored on the remote
/// (plugin_screensaver_entry_ui_test.py).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const plugin = <String, Object?>{
    'id': 'hello',
    'name': 'Hello World',
    'description': 'A sample plugin',
    'version': '1.0.0',
    'enabled': true,
    'running': true,
    'settings': <Object?>[],
    'commands': <Object?>[],
    'values': <String, Object?>{},
  };

  Future<AppContainer> open(
    WidgetTester tester,
    String mode, {
    bool installed = true,
    bool pluginsEnabled = true,
    Size size = const Size(500, 6000),
  }) async {
    SharedPreferences.setMockInitialValues({
      'ks.screensaver.enabled': true,
      'ks.screensaver.mode': mode,
    });
    final container = AppContainer();
    await container.settings.init();
    container.plugins.installed.value = [if (installed) plugin];
    container.plugins.enabled.value = pluginsEnabled;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(container: container)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    return container;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> tab(WidgetTester tester, String title) async {
    await tester.tap(find.text(title).first);
    await settle(tester);
  }

  final entry = find.widgetWithText(ListTile, 'Hello World');

  testWidgets('the selected plugin screensaver links to its plugin page '
      'above Widgets', (tester) async {
    await open(tester, 'plugin:hello:dvd');
    await tab(tester, 'Screensaver');
    expect(entry, findsOneWidget);
    expect(find.text('A sample plugin'), findsOneWidget);
    final widgets = find.widgetWithText(ListTile, 'Widgets');
    expect(
      tester.getTopLeft(entry).dy,
      lessThan(tester.getTopLeft(widgets).dy),
    );
    await tester.tap(entry);
    await settle(tester);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Hello World'),
      ),
      findsOneWidget,
    );
    expect(find.byType(SubpageSettingsScreen), findsOneWidget);
  });

  testWidgets('a stock mode has no plugin entry', (tester) async {
    await open(tester, 'clock');
    await tab(tester, 'Screensaver');
    expect(entry, findsNothing);
  });

  testWidgets('a plugin that is not installed has no entry', (tester) async {
    await open(tester, 'plugin:hello:dvd', installed: false);
    await tab(tester, 'Screensaver');
    expect(entry, findsNothing);
  });

  testWidgets('no entry while Enable Plugins is off', (tester) async {
    await open(tester, 'plugin:hello:dvd', pluginsEnabled: false);
    await tab(tester, 'Screensaver');
    expect(entry, findsNothing);
  });

  testWidgets('on a wide screen the entry moves the rail to Plugin Manager', (
    tester,
  ) async {
    await open(tester, 'plugin:hello:dvd', size: const Size(1400, 6000));
    await tab(tester, 'Screensaver');
    await tester.tap(entry);
    await settle(tester);
    expect(entry, findsNothing);
    // The pane's title row carries the plugin's name behind a back arrow.
    expect(find.text('Hello World'), findsWidgets);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await settle(tester);
    // Back lands on Plugin Manager's list, the rail's selection.
    expect(find.text('Enable Plugins'), findsOneWidget);
    // The list's refresh waits out its timeout with no plugin host here,
    // then its error toast times out.
    await tester.pump(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 5));
  });
}
