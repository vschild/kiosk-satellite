import 'dart:isolate';

import '../engine.dart';
import '../isolate_engine.dart';
import 'pryon_catalog.dart';
import 'pryon_isolate.dart';

/// Amazon's wake word engine, on the Echo images only.
///
/// The image runs the engine and its models as a service (PryonCatalog).
/// [pryonIsolateEntry] streams the mic to it and turns what it spots into
/// detections; the base owns the mic and the pre-roll as for the other
/// engines.
///
/// The service reports where the wake word ended, so the stream starts
/// right after it.
class PryonEngine extends IsolateWakeEngine {
  PryonEngine(super.log, {super.mic, super.spawner, super.micPermission});

  @override
  String get tag => 'pryon';

  @override
  WakeWordEngineType get engineType => WakeWordEngineType.pryon;

  @override
  void Function(SendPort) get isolateEntry => pryonIsolateEntry;

  @override
  bool get wakeEndIsAligned => true;

  @override
  Future<WakeModelPayload?> loadModels(WakeWordConfig config) async {
    final models = <Map<String, Object>>[];
    for (final ref in config.models) {
      final entry = _entry(ref);
      if (entry == null) {
        log.error(tag, 'the service has no "${ref.id}"');
        continue;
      }
      models.add(entry);
    }
    // Only next to a wake word: the service listens with the models of the
    // wake words, and the stop word comes along in one of them.
    var hasStop = false;
    final stopRef = config.stopModel;
    if (stopRef != null && models.isNotEmpty) {
      final entry = _entry(stopRef);
      if (entry != null) {
        models.add({...entry, 'stop': true});
        hasStop = true;
      } else {
        log.error(tag, 'the service has no stop word "${stopRef.id}"');
      }
    }
    return WakeModelPayload(
      models: models,
      hasStopModel: hasStop,
      extraInit: {'socketPath': PryonCatalog.socketPath},
    );
  }

  Map<String, Object>? _entry(WakeWordModelRef ref) {
    final word = PryonCatalog.byUrl(ref.manifestUrl);
    if (word == null) return null;
    return {
      'id': ref.id,
      'wakeWord': ref.wakeWord,
      'model': word.model,
      'keyword': word.keyword,
      'thresholdOffset': ref.thresholdOffset,
      if (word.acceptThreshold != null)
        'acceptThreshold': word.acceptThreshold!,
    };
  }
}
