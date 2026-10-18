import 'dart:typed_data';

/// What Fleet Management needs from the plugin runtime. It stays off the
/// command surface: [fleetState] carries plugin secrets in the clear, which
/// no admin listing shows.
abstract interface class FleetPluginHost {
  /// Every installed plugin as the fleet carries it: `id`, `name`,
  /// `version`, `sha256` (the package), `source`, `enabled`, `config` (the
  /// secrets in the clear), `actionOptions`, `secretKeys` and `kept`
  /// (whether the package file is here to pass on).
  Future<List<Map<String, Object?>>> fleetState();

  /// The package file of an installed plugin. Null when this kiosk does not
  /// have it and cannot fetch it again from the plugin's repository.
  Future<String?> fleetPackage(String id);

  /// Installs a package a leader sent, with the source it came from.
  Future<void> fleetInstall(
    Uint8List bytes, {
    required String sha256,
    Map<String, Object?>? source,
  });

  /// Takes a leader's settings, action placements and enabled state for
  /// one installed plugin. Secrets left out keep this kiosk's own value.
  Future<void> fleetConfigure(String id, Map<String, Object?> entry);

  Future<void> fleetRemove(String id);
}
