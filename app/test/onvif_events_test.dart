import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/home_assistant/home_assistant_manager.dart';
import 'package:kiosk_satellite/managers/motion/onvif_events_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ONVIF motion events (issue #1098): which source drives them and what
/// reaches the native ONVIF server. Home Assistant is left unconfigured,
/// so the entity source's states are fed in as the subscription would
/// deliver them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const entity = 'binary_sensor.hallway_occupancy';
  const onvif = <String, Object>{
    'ks.camera.enabled': true,
    'ks.camera.rtsp.enabled': true,
    'ks.camera.rtsp.protocol': 'onvif',
    'ks.camera.onvif.events': true,
  };

  late EventBus bus;
  late CommandRegistry commands;
  late SettingsManager settings;
  late OnvifEventsManager events;
  late List<({bool enabled, bool motion})> pushed;

  Future<void> start(Map<String, Object> prefs, {bool present = false}) async {
    SharedPreferences.setMockInitialValues(prefs);
    bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    commands.register(
      Command(
        name: 'getPersonSensor',
        description: 'test',
        handler: (_) async => CommandResult.ok({'present': present}),
      ),
    );
    pushed = [];
    events = OnvifEventsManager(
      bus,
      commands,
      log,
      settings,
      HomeAssistantManager(bus, commands, log, settings),
      push: ({required enabled, required motion}) async =>
          pushed.add((enabled: enabled, motion: motion)),
    );
    await events.init();
  }

  tearDown(() => events.dispose());

  Future<void> set(String key, Object value) async {
    await settings.setFromJson(key, value);
    await pumpEventQueue();
  }

  test('stay off until ONVIF streaming and the switch are on', () async {
    await start({...onvif, 'ks.camera.onvif.events': false});
    expect(pushed, [(enabled: false, motion: false)]);
    await set(defs.cameraOnvifEvents.key, true);
    expect(pushed.last, (enabled: true, motion: false));
    await set(defs.cameraStreamingProtocol.key, 'rtsp');
    expect(pushed.last, (enabled: false, motion: false));
  });

  test('the camera source follows the Motion sensor and its delay', () {
    fakeAsync((async) {
      start({
        ...onvif,
        'ks.motion.sensor': true,
        'ks.motion.sensor_off_delay': 5,
      });
      async.flushMicrotasks();
      bus.publish(const MotionDetected());
      async.flushMicrotasks();
      expect(pushed.last, (enabled: true, motion: true));
      async.elapse(const Duration(seconds: 3));
      bus.publish(const MotionDetected());
      async.elapse(const Duration(seconds: 4));
      expect(pushed.last.motion, isTrue);
      async.elapse(const Duration(seconds: 2));
      expect(pushed.last, (enabled: true, motion: false));
    });
  });

  test('the camera source sends nothing with the Motion sensor off', () async {
    await start(onvif);
    bus.publish(const MotionDetected());
    await pumpEventQueue();
    expect(pushed, [(enabled: true, motion: false)]);
  });

  test('the person source follows the person sensor', () async {
    await start({
      ...onvif,
      'ks.camera.onvif.events_source': 'person',
      'ks.person.sensor': true,
    }, present: true);
    expect(pushed.last, (enabled: true, motion: true));
    bus.publish(const PersonSensorChanged(present: false));
    await pumpEventQueue();
    expect(pushed.last.motion, isFalse);
    bus.publish(const PersonSensorChanged(present: true));
    await pumpEventQueue();
    expect(pushed.last.motion, isTrue);
    await set(defs.personSensorEnabled.key, false);
    expect(pushed.last.motion, isFalse);
  });

  test('the entity source follows the picked sensor only', () async {
    await start({
      ...onvif,
      'ks.camera.onvif.events_source': 'entity',
      'ks.camera.onvif.events_entity': entity,
    });
    events.applyEntityState('binary_sensor.other', 'on');
    expect(pushed.last.motion, isFalse);
    events.applyEntityState(entity, 'on');
    expect(pushed.last, (enabled: true, motion: true));
    events.applyEntityState(entity, 'unavailable');
    expect(pushed.last.motion, isFalse);
    expect((await commands.execute('getOnvifEvents', const {})).data, {
      'enabled': true,
      'source': 'entity',
      'motion': false,
    });
  });
}
