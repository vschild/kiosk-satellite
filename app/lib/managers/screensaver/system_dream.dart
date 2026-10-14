/// Copy for the Android screensaver mode. These sentences are also the
/// localization keys, so a change here has to land in the English catalog.
const androidScreensaverHint =
    'Starts the screensaver chosen in Android settings. The dashboard '
    'stays as it is and comes back when that screensaver ends.';

const androidScreensaverSettingsTitle = 'Android screensaver settings';

const androidScreensaverSettingsDetail =
    'Opens Settings > Display > Screen saver.';

const androidScreensaverTurnedOff =
    "Android's screensaver is turned off. Turn it on in Settings > "
    'Display > Screen saver.';

const androidScreensaverWillStart =
    'Android will start the screensaver selected in system settings.';

const androidScreensaverDidNotStart =
    'The Android screensaver did not start. This device may not allow '
    'apps to launch it. Check Settings > Display > Screen saver, or '
    'choose another mode.';

const androidScreensaverAndroidOnly =
    'Starting the Android screensaver is only available on Android.';

const androidScreensaverCannotStart =
    'This device cannot start the Android screensaver. Check Settings > '
    'Display > Screen saver, or choose another mode.';

const androidScreensaverModernLimit =
    'On Android 14 and later the system often blocks apps from starting '
    'its screensaver. If nothing appears at the idle timeout, pick '
    'another mode or use a device that still allows it.';

/// Maps a [startSystemDream] failure code onto the sentence the UI shows.
/// An unexpected platform message is kept as-is.
String androidScreensaverMessage(String? code) => switch (code) {
  'disabled' => androidScreensaverTurnedOff,
  'unavailable' => androidScreensaverCannotStart,
  'did_not_start' => androidScreensaverDidNotStart,
  'android_only' => androidScreensaverAndroidOnly,
  null || '' => androidScreensaverCannotStart,
  _ => code!,
};
