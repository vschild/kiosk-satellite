import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/dlna/dlna_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Media on screen holds the screensaver's idle clock while it plays. A
/// periodic activity signal used to do this, and an idle timeout shorter
/// than its 15 s period let the screensaver start over a playing video.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsManager settings;
  late DlnaManager dlna;
  late List<bool> holds;

  // Never init()ed, like the background audio tests: init binds real
  // sockets, and the hold follows the transport notifiers alone.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    holds = [];
    commands.register(
      Command(
        name: 'holdScreensaver',
        description: 'records holds',
        handler: (p) async {
          if (p['holder'] == 'dlna') holds.add(p['held'] == true);
          return const CommandResult.ok();
        },
      ),
    );
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    dlna = DlnaManager(bus, commands, log, settings);
  });

  DlnaMedia media(String kind) =>
      DlnaMedia(uri: 'http://x/y', kind: kind, metadata: '');

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a playing video holds the screensaver until it stops', () async {
    dlna.media.value = media('video');
    dlna.transportState.value = 'PLAYING';
    await settle();
    expect(holds, [true]);
    await dlna.stopPlayback();
    await settle();
    expect(holds, [true, false]);
  });

  test('pausing lets the screensaver go and resuming holds it again', () async {
    dlna.media.value = media('video');
    dlna.transportState.value = 'PLAYING';
    dlna.transportState.value = 'PAUSED_PLAYBACK';
    dlna.transportState.value = 'PLAYING';
    await settle();
    expect(holds, [true, false, true]);
  });

  test('media loaded but not playing holds nothing', () async {
    dlna.media.value = media('video');
    dlna.pending.value = true;
    await settle();
    expect(holds, isEmpty);
  });

  test('background audio never holds the screensaver', () async {
    await settings.set(defs.dlnaAudioBackground, true);
    dlna.media.value = media('audio');
    dlna.transportState.value = 'PLAYING';
    await settle();
    expect(holds, isEmpty);
  });
}
