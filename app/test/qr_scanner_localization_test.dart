import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:kiosk_satellite/core/app_locales.dart';
import 'package:kiosk_satellite/l10n/generated/ui_strings.dart';
import 'package:kiosk_satellite/l10n/generated/ui_strings_en.dart';
import 'package:kiosk_satellite/ui/token_qr_scanner.dart';

class _Spanish extends UiStringsEn {
  @override
  String get setupQrTitle => 'Escanea el código QR del token';
  @override
  String get setupQrHelp =>
      'Aparece junto a un token recién creado en tu perfil de Home Assistant.';
  @override
  String get setupQrCameraFailed => 'No se pudo iniciar la cámara.';
  @override
  String get setupQrFlashOff => 'Apagar la linterna';
  @override
  String get setupQrFlashOn => 'Encender la linterna';
  @override
  String get setupQrFlipCamera => 'Cambiar de cámara';
  @override
  String get setupQrScreenLightOff => 'Apagar la luz de pantalla';
  @override
  String get setupQrScreenLightOn => 'Encender la luz de pantalla';
  @override
  String get commonCancel => 'Cancelar';
}

class _Delegate extends LocalizationsDelegate<UiStrings> {
  const _Delegate();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<UiStrings> load(Locale locale) => SynchronousFuture(
    locale.languageCode == 'es' ? _Spanish() : UiStringsEn(),
  );
  @override
  bool shouldReload(_Delegate old) => false;
}

class _Scanner extends MobileScannerPlatform {
  final captures = StreamController<BarcodeCapture?>.broadcast();
  final torch = StreamController<TorchState>.broadcast();
  var starts = 0;
  var toggles = 0;
  var failed = false;
  final directions = <CameraFacing>[];
  var cameras = 2;
  final missing = <CameraFacing>{};
  Completer<void>? startGate;
  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => torch.stream;
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    directions.add(options.cameraDirection);
    expectSync(options.formats, [BarcodeFormat.qrCode]);
    await startGate?.future;
    if (failed) {
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.permissionDenied,
      );
    }
    if (missing.contains(options.cameraDirection)) {
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.unsupported,
      );
    }
    return MobileScannerViewAttributes(
      cameraDirection: options.cameraDirection,
      numberOfCameras: cameras,
      currentTorchMode: options.cameraDirection == CameraFacing.front
          ? TorchState.unavailable
          : TorchState.off,
      size: const Size(320, 600),
    );
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> toggleTorch() async {
    toggles++;
    torch.add(TorchState.on);
  }
}

Finder action(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == tooltip,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Scanner scanner;
  late ValueNotifier<Locale> language;
  setUp(() {
    scanner = _Scanner();
    MobileScannerPlatform.instance = scanner;
    language = ValueNotifier(const Locale('es'));
  });
  tearDown(() async {
    language.dispose();
    await scanner.captures.close();
    await scanner.torch.close();
  });
  Future<void> show(
    WidgetTester tester,
    void Function(String?) result, {
    bool screenLight = false,
    ValueChanged<bool>? onScreenLight,
    ValueChanged<bool>? lightScreen,
  }) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ValueListenableBuilder<Locale>(
        valueListenable: language,
        builder: (context, locale, _) => MaterialApp(
          locale: locale,
          supportedLocales: const [Locale('en'), Locale('es')],
          localizationsDelegates: const [
            _Delegate(),
            ...appLocalizationsDelegates,
          ],
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result(
                  await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => TokenQrScanner(
                        screenLight: screenLight,
                        onScreenLight: onScreenLight,
                        lightScreen: lightScreen,
                      ),
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'scanner translates without restarting capture or altering token',
    (tester) async {
      String? result;
      var returns = 0;
      await show(tester, (value) {
        result = value;
        returns++;
      });
      expect(find.text('Escanea el código QR del token'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(scanner.directions, [CameraFacing.front]);
      expect(
        tester.widget<IconButton>(action('Encender la linterna')).onPressed,
        isNull,
      );
      await tester.tap(action('Cambiar de cámara'));
      await tester.pumpAndSettle();
      expect(scanner.directions, [CameraFacing.front, CameraFacing.back]);
      await tester.tap(action('Encender la linterna'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Apagar la linterna'), findsOneWidget);
      expect(scanner.toggles, 1);
      language.value = const Locale('en');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Turn off the flashlight'), findsOneWidget);
      expect(find.byTooltip('Flip camera'), findsOneWidget);
      language.value = const Locale('es');
      await tester.pumpAndSettle();
      expect(scanner.starts, 2);
      await tester.tap(action('Cambiar de cámara'));
      await tester.pumpAndSettle();
      expect(scanner.directions.last, CameraFacing.front);
      scanner.captures.add(
        const BarcodeCapture(
          barcodes: [
            Barcode(rawValue: '  Raw.Token+KeepCase  '),
            Barcode(rawValue: 'second'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(result, 'Raw.Token+KeepCase');
      expect(returns, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('a rear-only device falls back and disables camera switching', (
    tester,
  ) async {
    scanner.cameras = 1;
    scanner.missing.add(CameraFacing.front);
    await show(tester, (_) {});
    expect(scanner.directions, [CameraFacing.front, CameraFacing.back]);
    expect(find.text('No se pudo iniciar la cámara.'), findsNothing);
    expect(
      tester.widget<IconButton>(action('Cambiar de cámara')).onPressed,
      isNull,
    );
    await tester.tap(action('Encender la linterna'));
    await tester.pumpAndSettle();
    expect(scanner.toggles, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('a front-only device scans without offering a camera switch', (
    tester,
  ) async {
    scanner.cameras = 1;
    await show(tester, (_) {});
    expect(scanner.directions, [CameraFacing.front]);
    expect(
      tester.widget<IconButton>(action('Cambiar de cámara')).onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('switching is guarded and cancel works while a camera starts', (
    tester,
  ) async {
    var returned = false;
    await show(tester, (_) => returned = true);
    scanner.startGate = Completer<void>();
    final flip = tester.widget<IconButton>(action('Cambiar de cámara'));
    flip.onPressed!();
    flip.onPressed!();
    await tester.pump();
    expect(scanner.directions, [CameraFacing.front, CameraFacing.back]);
    expect(
      tester.widget<IconButton>(action('Cambiar de cámara')).onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Cancelar'));
    await tester.pumpAndSettle();
    scanner.startGate!.complete();
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('no available camera stops after one fallback attempt', (
    tester,
  ) async {
    scanner.missing.addAll([CameraFacing.front, CameraFacing.back]);
    await show(tester, (_) {});
    expect(scanner.directions, [CameraFacing.front, CameraFacing.back]);
    expect(find.text('No se pudo iniciar la cámara.'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancelar'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('camera failure and cancel remain usable in Spanish', (
    tester,
  ) async {
    scanner.failed = true;
    var returned = false;
    await show(tester, (value) {
      expect(value, isNull);
      returned = true;
    });
    expect(find.text('No se pudo iniciar la cámara.'), findsOneWidget);
    expect(scanner.directions, [CameraFacing.front]);
    await tester.tap(find.byTooltip('Cancelar'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('the screen light shrinks the preview without a restart', (
    tester,
  ) async {
    String? result;
    final lights = <bool>[];
    final bright = <bool>[];
    await show(
      tester,
      (value) => result = value,
      onScreenLight: lights.add,
      lightScreen: bright.add,
    );
    expect(bright, isEmpty);
    Color background() =>
        tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor!;
    expect(background(), Colors.black);
    expect(tester.getSize(find.byType(MobileScanner)), const Size(320, 600));
    await tester.tap(action('Encender la luz de pantalla'));
    await tester.pumpAndSettle();
    expect(background(), Colors.white);
    // A QR code scan keeps a square preview, scaled down on a small screen.
    expect(tester.getSize(find.byType(MobileScanner)), const Size(144, 144));
    expect(find.byTooltip('Apagar la luz de pantalla'), findsOneWidget);
    expect(lights, [true]);
    expect(bright, [true]);
    expect(scanner.starts, 1);
    scanner.captures.add(
      const BarcodeCapture(barcodes: [Barcode(rawValue: '0012345')]),
    );
    await tester.pumpAndSettle();
    expect(result, '0012345');
    expect(bright, [true, false], reason: 'a read lets go of the panel');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('a remembered screen light opens lit and turns off', (
    tester,
  ) async {
    final lights = <bool>[];
    final bright = <bool>[];
    await show(
      tester,
      (_) {},
      screenLight: true,
      onScreenLight: lights.add,
      lightScreen: bright.add,
    );
    expect(tester.getSize(find.byType(MobileScanner)), const Size(144, 144));
    expect(bright, [true]);
    await tester.tap(action('Apagar la luz de pantalla'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(MobileScanner)), const Size(320, 600));
    expect(lights, [false]);
    expect(bright, [true, false]);
    expect(scanner.starts, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('cancel turns full brightness off', (tester) async {
    final bright = <bool>[];
    await show(tester, (_) {}, screenLight: true, lightScreen: bright.add);
    await tester.tap(find.byTooltip('Cancelar'));
    await tester.pumpAndSettle();
    expect(bright, [true, false]);
    await tester.pumpWidget(const SizedBox());
  });
}
