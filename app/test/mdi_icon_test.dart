import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/ui/mdi_icon.dart';

/// The bundled Material Design Icons (see tool/generate_mdi.py).
///
/// Home Assistant names icons in its own vocabulary and the app has to
/// answer with the right shape, so what is pinned here is the lookup:
/// the name spellings that arrive from automations, the alias hop that
/// keeps a renamed icon working, and the fallback when there is nothing
/// to draw.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // The shards are read from disk here: waiting on the asset channel
    // outside a pumping widget test deadlocks, and the files are the same
    // ones the bundle carries.
    MdiIcons.readShard = (key) => File(key).readAsString();
  });

  test('names arrive in several spellings and all resolve', () async {
    for (final spelling in [
      'washing-machine',
      'mdi:washing-machine',
      'MDI:Washing-Machine',
      '  mdi:washing-machine  ',
    ]) {
      final path = await MdiIcons.path(spelling);
      expect(path, isNotNull, reason: spelling);
      expect(path, startsWith('M'), reason: spelling);
    }
  });

  test('a renamed icon still draws through its alias', () async {
    // "123" is an alias of "numeric", and the two live in different
    // files, so this pins the second read the hop needs as well.
    final alias = await MdiIcons.path('123');
    expect(alias, isNotNull);
    expect(alias, await MdiIcons.path('numeric'));
  });

  test('icons whose names do not start with a letter are found too', () async {
    expect(await MdiIcons.path('8-track'), isNotNull);
  });

  test('names with numbers keep the hyphen Home Assistant uses', () async {
    // Battery entities ask for these, and a plugin picks cpu-64-bit.
    for (final name in ['battery-10', 'cpu-64-bit', 'numeric-1-box']) {
      expect(await MdiIcons.path(name), isNotNull, reason: name);
    }
    // Earlier builds stored them without it, so old picks still draw.
    expect(await MdiIcons.path('battery10'), await MdiIcons.path('battery-10'));
  });

  test(
    'a name that is not an icon resolves to nothing, not an error',
    () async {
      expect(await MdiIcons.path('no-such-icon-anywhere'), isNull);
      expect(await MdiIcons.path('washing machine'), isNull);
      expect(await MdiIcons.path(''), isNull);
      expect(MdiIcons.looksLikeIcon('mdi:washing-machine'), isTrue);
      expect(MdiIcons.looksLikeIcon('<script>'), isFalse);
    },
  );

  testWidgets('the widget draws the icon, and the fallback until it can', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MdiIcon(
            name: 'mdi:washing-machine',
            size: 40,
            color: Colors.white,
            fallback: Icons.info_outline,
          ),
        ),
      ),
    );
    // The path is read from the bundle, so the first frame is the
    // fallback rather than an empty hole.
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.info_outline), findsNothing);

    // A name with no icon behind it keeps the fallback for good.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MdiIcon(
            name: 'mdi:definitely-not-an-icon',
            size: 40,
            color: Colors.white,
            fallback: Icons.info_outline,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });
  test('the icon picker searches names by their words', () async {
    final all = await MdiIcons.names();
    expect(all.length, greaterThan(7000));
    // Renamed icons are left out, so each icon shows once.
    expect(all, isNot(contains('123')));
    expect(all, contains('garage-open'));
    final found = await MdiIcons.search('garage open');
    expect(found.first, 'garage-open');
    expect(found, everyElement(allOf(contains('garage'), contains('open'))));
    expect(await MdiIcons.search(''), hasLength(60));
  });

  test('several paths resolve in one read per letter', () async {
    var reads = 0;
    final read = MdiIcons.readShard;
    MdiIcons.forget();
    MdiIcons.readShard = (key) {
      reads++;
      return read(key);
    };
    addTearDown(() {
      MdiIcons.readShard = read;
      MdiIcons.forget();
    });
    final paths = await MdiIcons.paths([
      'mdi:garage',
      'garage-open',
      'gate',
      'mdi:not-an-icon-at-all',
    ]);
    expect(paths.keys, unorderedEquals(['garage', 'garage-open', 'gate']));
    // One for the three under g, one for the name under n.
    expect(reads, 2);
    // A held set answers without reading again.
    await MdiIcons.hold();
    reads = 0;
    expect(await MdiIcons.path('home-outline'), isNotNull);
    expect(reads, 0);
    MdiIcons.release();
  });
}
