# Echo Dot

This setup has been verified on a 2nd generation Echo Dot (`biscuit`) running the [Kiosk Satellite Edition of LineageOS for the Echo Dot](https://github.com/jxlarrea/lineageos-biscuit-kiosk-satellite), a LineageOS 14.1 (Android 7.1.2) image tuned for Kiosk Satellite. The Dot has no screen, so Kiosk Satellite runs headless on it: a voice satellite, intercom, alarm clock, timer and speaker for Home Assistant, set up and managed entirely from the remote admin.

## Headless Mode

Kiosk Satellite turns headless on its own on any device whose display is a stub (the Dot reports a 1x1 display). Nothing needs to be switched on. On a headless device:

- No screen is ever drawn. There is no WebView, dashboard, screensaver, camera or camera view, and the app never opens an Activity.
- The Kiosk Satellite Service starts when the device boots, whatever **Start on boot** says. The [Home Launcher](home-launcher.md) is not needed.
- Voice Satellite, the intercom, alarms, timers, the [DLNA renderer](dlna.md), the [Sendspin player](sendspin.md), ESPHome, [Fleet Management](#fleet-management) and plugins work as usual.
- Plugins that need a screen do not install. See [Plugins](#plugins).
- The remote admin leaves out every page and control that needs a screen: Web Browsing, Screensaver, Camera, Camera Streams, Kiosk Mode, Lockdown Mode, Home Launcher and App Launcher, the dashboard settings of Home Assistant, the screenshot and the screen tiles of the Overview, and the display settings on the other pages.
- ESPHome leaves out the screen, screensaver, dashboard and camera entities.
- The DLNA renderer offers audio only, so Home Assistant's media browser lists only what the Dot can play.
- Intercom calls are always hands-free.
- **Remote management** stays on, since the remote admin is the only way in.
- Android is kept awake. Asleep, Android drops the Action button before the app can hear it.

## Before You Start

The Dot needs the [Kiosk Satellite Edition of LineageOS for the Echo Dot](https://github.com/jxlarrea/lineageos-biscuit-kiosk-satellite). Follow its README to unlock the Dot, install the image and join Wi-Fi. On first boot the latest Kiosk Satellite release is downloaded, installed, given every permission it needs and made the device owner, so there are no adb commands to run.

The image also improves on the upstream port in ways that matter for Kiosk Satellite: the wake word works over music at full volume, the microphone is louder, the light ring no longer strobes and more memory stays free. Its README lists every change.

## Setup

Open `http://<dot ip>:2324` in a browser. The image's README shows how to find the Dot's IP address. In the setup wizard, set an admin password, the Home Assistant connection and the Voice Satellite wake word. The wizard skips the dashboard step. Then add the Dot in Home Assistant under **Settings > Devices & services**, where it shows up as discovered.

The Action button reaches Kiosk Satellite through an accessibility service, which is switched on at every boot. Force-stopping Kiosk Satellite, with `adb shell am force-stop` or **Force stop** in Android's app settings, switches the service off until the next reboot. **Restart app** does not switch it off.

## Wake Word

Pick the engine with **Wake word engine** under **Voice Satellite > Wake Word**, with the **VS Wake word engine** select in Home Assistant or in the setup wizard. The Dot offers four:

| Engine | What it is |
|---|---|
| vsWakeWord | The default. Its models ship with the app. |
| microWakeWord | The engine of Home Assistant's voice hardware. Its models ship with the app, and it also offers the custom models Home Assistant has. |
| openWakeWord | Its models ship with the app. |
| Amazon | The engine the Dot shipped with, running Amazon's own wake word models. Needs the Kiosk Satellite Edition image 2026.10.3 or newer. Other devices do not offer it. |

The first three also take your own models. See [Custom wake word models](custom-wake-words.md).

### Amazon

The image runs Amazon's wake word engine on the Dot itself, so Kiosk Satellite sends it the microphone audio locally and nothing goes to Amazon. Amazon's models are made per locale. With **Amazon** picked, a **Wake word language** select shows up under the engine. It follows Kiosk Satellite's language by default and falls back to English (United States) if the image has no models for it. The Wake word selects in Home Assistant then offer the wake words of that locale:

| Language | Locale | Wake words |
|---|---|---|
| English (United States) | `en-US` | Alexa, Echo, Computer, Amazon, Ziggy, Hey Disney |
| English (Canada) | `en-CA` | Alexa, Echo, Computer, Amazon, Ziggy, Hey Disney |
| English (United Kingdom) | `en-GB` | Alexa, Echo, Computer |
| English (Australia) | `en-AU` | Alexa, Echo, Computer |
| English (India) | `en-IN` | Alexa, Echo, Computer |
| Hindi (India) | `hi-IN` | Alexa, Echo, Computer |
| Spanish (United States) | `es-US` | Alexa, Echo, Computer |
| Spanish (Mexico) | `es-MX` | Alexa, Echo, Amazon, Ziggy |
| Spanish (Spain) | `es-ES` | Alexa, Echo |
| French (France) | `fr-FR` | Alexa, Echo |
| French (Canada) | `fr-CA` | Alexa, Echo |
| German (Germany) | `de-DE` | Alexa, Echo, Computer |
| Italian (Italy) | `it-IT` | Alexa, Echo, Computer |
| Portuguese (Brazil) | `pt-BR` | Alexa, Echo |
| Japanese (Japan) | `ja-JP` | Alexa, Echo, Computer |
| Dutch (Netherlands) | `nl-NL` | Alexa, Echo |
| Arabic (Saudi Arabia) | `ar-SA` | Alexa, Echo |

Each model spots one or more wake words. The Alexa, Echo and Computer models spot their own name, and some also spot Amazon, Ziggy or Hey Disney. A locale that Amazon gave the same model as another locale uses that model, so English (Australia) listens with the British models and Dutch with the German Alexa model. The Alexa model for English (United States) comes from the Dot's own firmware and the rest from Amazon's model servers.

Each model also has its own stop word, so **Stop word interruption** works as it does with the other engines. Saying "stop" ends a ringing timer or a reply. **Wake word sensitivity** applies too.

Amazon's engine uses more CPU and memory than vsWakeWord while it listens.

## Volume

The image removes the speaker's sound from the Dot's microphones while music plays, so the wake word works at any media volume, up to 100%. Keep the **Master volume** on the **Audio** page at 100%, which leaves the assistant, alarms and intercom at full strength, and set the media volume as you like.

## The Buttons

| Button | What it does |
|---|---|
| Action | Answers a ringing intercom call, stops a ringing alarm, dismisses a ringing timer or the voice turn, or ends an intercom call. With none of those happening, it starts a voice command. |
| Microphone | Mutes and unmutes Voice Satellite. The mute follows the Dot's microphone mute both ways, so the button, the **VS Mute** switch in Home Assistant and the remote admin always agree, and the light ring shows it. |
| Volume up and down | Change the volume. With **Volume buttons control the player** set to **While the player is playing** under Media Player, they control the followed player or the Music Assistant group the Dot plays in instead. This needs the Kiosk Satellite Edition image 2026.10.2 or newer. Each press is one step: holding a button does not repeat. |

The Action button can also run any gesture action. Add a **Button** gesture on the [Gestures](gestures.md) page for a press, a double press or a hold of the Action button. A press no gesture claims keeps the job above. The LineageOS build handles the microphone and volume buttons itself, so they cannot be mapped.

[Claps](gestures.md#claps) work as well, since they only need the microphone.

## The Light Ring

The ring shows voice activity, timers, alarms, intercom calls, notifications and the microphone mute in the colors an Echo Dot uses. Each can be changed or switched off on the **LED Control** page. See [LED Control](led-control.md).

## Plugins

[Plugins](plugins.md) work on the Dot, except for the parts that need a screen:

- A plugin that publishes entities, reacts to Voice Satellite or talks to Home Assistant runs as it would anywhere else.
- A plugin built around overlays or screensavers does not install. The Plugin Manager shows **This plugin needs a screen** and keeps its Install button disabled, and a fleet leader that tries to push one shows the same reason on the Dot's row.
- A plugin can declare that it also runs without a screen. It then installs and leaves out its overlays and screensavers on the Dot.

The **LED Control** page drives the light ring itself, so the ring needs no plugin.

## Fleet Management

The Dot can follow a [fleet](fleet.md) leader like any other kiosk, but give it a profile of its own. A leader with a screen does not offer the **Button** gesture trigger, so a profile that includes the **Gestures** category sends a gesture list without button gestures and replaces the Dot's at every sync.

- Create a profile on the leader without the **Gestures** category and assign the Dot, and any other device without a screen, to it. To keep the rest of the Gestures category in sync, keep the category and exclude only the **Gestures** setting, the gesture list itself.
- If the Dot only needs updates from the fleet, assign it to the built-in **Updates only** profile.

Then set up the Button gestures on the Dot's own remote admin. The other categories are safe to sync: the Dot ignores the leader's values for the settings it holds fixed, such as the screensaver switch.

## What to Know

- **Updates.** Kiosk Satellite is the device owner on the image, so updates install silently, with no screen to confirm them on.
- **Resources.** With the wake word listening, Kiosk Satellite uses about 5% of one core and 100 MB of the Dot's 480 MB of RAM while idle.

## Memory

The Overview's RAM tile counts only memory nobody holds, usually about 0.3 GB on the Dot. Android keeps the rest filled with cached apps and files it gives back on demand. The image already leaves out the system apps the Dot does not need and sets up 256 MB of compressed swap (zram).

Bluetooth is off on a fresh install, which saves 15 to 20 MB. If you want the [Bluetooth proxy](esphome.md), turn it on with `adb shell biscuit_service bt on`. It stays on across reboots, and `adb shell biscuit_service bt off` turns it off again.
