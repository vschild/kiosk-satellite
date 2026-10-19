import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'theme.dart';
import '../l10n/messages.dart';

/// What a scan ended with: the code and its format, or why there is none.
/// The format and error names are the plugin SDK's.
class CodeScanOutcome {
  const CodeScanOutcome.read(String this.value, String this.format)
    : error = null;
  const CodeScanOutcome.failed(String this.error) : value = null, format = null;

  final String? value;
  final String? format;
  final String? error;

  Map<String, Object?> toJson() => error == null
      ? {'ok': true, 'value': value, 'format': format}
      : {'ok': false, 'error': error};
}

/// The SDK's format names by ML Kit's format values.
const _formatNames = {
  256: 'qr_code',
  4096: 'aztec',
  16: 'data_matrix',
  2048: 'pdf417',
  32: 'ean_13',
  64: 'ean_8',
  512: 'upc_a',
  1024: 'upc_e',
  1: 'code_128',
  2: 'code_39',
  4: 'code_93',
  8: 'codabar',
  128: 'itf',
};

/// The scanner formats for SDK format names. Empty reads every format.
List<BarcodeFormat> codeScanFormats(List<String> names) => [
  for (final entry in _formatNames.entries)
    if (names.contains(entry.value)) BarcodeFormat.fromRawValue(entry.key),
];

/// Full-screen scanner for QR codes and barcodes. The setup wizard reads
/// the token QR code Home Assistant shows next to a new long-lived access
/// token with it, and plugins with the barcode capability read any code.
/// Pops with [result] of the first code read, or of why it ended: closed
/// (`canceled`), [timeout] passed (`timeout`), [cancel] completing with
/// its reason or, with [closeOnError], a camera that does not start
/// (`camera_failed`). The camera stops before the scanner pops, so the
/// next session can bind it at once.
class CodeScanner extends StatefulWidget {
  const CodeScanner({
    super.key,
    required this.title,
    required this.help,
    this.source,
    this.formats = const [],
    this.facing = CameraFacing.front,
    this.timeout,
    this.cancel,
    this.closeOnError = false,
    this.result = _outcome,
  });

  final String title;
  final String help;

  /// Who asked for the scan, shown under [help].
  final String? source;
  final List<BarcodeFormat> formats;
  final CameraFacing facing;
  final Duration? timeout;
  final Future<String>? cancel;
  final bool closeOnError;

  /// What the route pops with for an outcome.
  final Object? Function(CodeScanOutcome outcome) result;

  static Object? _outcome(CodeScanOutcome outcome) => outcome;

  @override
  State<CodeScanner> createState() => _CodeScannerState();
}

class _CodeScannerState extends State<CodeScanner> {
  late final _controller = MobileScannerController(
    facing: widget.facing,
    formats: widget.formats,
  );

  /// A capture can carry several frames' worth of hits; pop exactly once.
  bool _done = false;
  bool _switching = false;
  bool _initialCamera = true;
  Timer? _timeout;
  Timer? _failure;

  /// Two-dimensional codes are square. Everything else reads best in a
  /// wide frame.
  bool get _square =>
      widget.formats.isNotEmpty &&
      widget.formats.every(
        (f) =>
            f == BarcodeFormat.qrCode ||
            f == BarcodeFormat.aztec ||
            f == BarcodeFormat.dataMatrix,
      );

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onCameraChanged);
    final timeout = widget.timeout;
    if (timeout != null) {
      _timeout = Timer(
        timeout,
        () => _finish(const CodeScanOutcome.failed('timeout')),
      );
    }
    widget.cancel?.then((reason) => _finish(CodeScanOutcome.failed(reason)));
  }

  void _onCameraChanged() {
    final state = _controller.value;
    if (_initialCamera) {
      if (state.isRunning) {
        _initialCamera = false;
      } else if (state.error?.errorCode == MobileScannerErrorCode.unsupported) {
        // A device with only the other camera must still be able to scan.
        _initialCamera = false;
        scheduleMicrotask(() {
          if (mounted && !_done) {
            unawaited(
              _controller.start(
                cameraDirection: widget.facing == CameraFacing.front
                    ? CameraFacing.back
                    : CameraFacing.front,
              ),
            );
          }
        });
        return;
      }
    }
    // The message stays up for a moment, so the person sees why it closed.
    if (widget.closeOnError && state.error != null && _failure == null) {
      _failure = Timer(
        const Duration(seconds: 3),
        () => _finish(const CodeScanOutcome.failed('camera_failed')),
      );
    }
  }

  Future<void> _flipCamera() async {
    if (_switching || _done || !_controller.value.isRunning) return;
    setState(() => _switching = true);
    try {
      await _controller.switchCamera();
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _failure?.cancel();
    _controller.removeListener(_onCameraChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value != null && value.isNotEmpty) {
        _finish(
          CodeScanOutcome.read(
            value,
            _formatNames[barcode.format.rawValue] ?? 'unknown',
          ),
        );
        return;
      }
    }
  }

  Future<void> _finish(CodeScanOutcome outcome) async {
    if (_done) return;
    _done = true;
    _timeout?.cancel();
    _failure?.cancel();
    try {
      await _controller.stop();
    } catch (_) {
      // A camera that never started has nothing to stop.
    }
    if (mounted) Navigator.of(context).pop(widget.result(outcome));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish(const CodeScanOutcome.failed('canceled'));
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    l10n(context).setupQrCameraFailed,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            // Viewfinder: a rounded frame in the middle, the copy above and
            // below it, everything readable over any camera image.
            Center(
              child: Container(
                width: _square ? 260 : 320,
                height: _square ? 260 : 200,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white70, width: 3),
                  borderRadius: BorderRadius.circular(Ks.radiusCard),
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                    child: Text(
                      widget.title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontFamily: Ks.displayFont,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      widget.help,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  ),
                  if (widget.source != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                      child: Text(
                        widget.source!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white54,
                        ),
                      ),
                    ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      spacing: 16,
                      children: [
                        _RoundAction(
                          icon: Icons.close,
                          tooltip: l10n(context).commonCancel,
                          onTap: () =>
                              _finish(const CodeScanOutcome.failed('canceled')),
                        ),
                        ValueListenableBuilder(
                          valueListenable: _controller,
                          builder: (context, state, _) => _RoundAction(
                            icon: Icons.flip_camera_android_outlined,
                            tooltip: l10n(context).setupQrFlipCamera,
                            onTap:
                                state.isRunning &&
                                    !_switching &&
                                    (state.availableCameras == null ||
                                        state.availableCameras! > 1) &&
                                    (state.cameraDirection ==
                                            CameraFacing.front ||
                                        state.cameraDirection ==
                                            CameraFacing.back)
                                ? _flipCamera
                                : null,
                          ),
                        ),
                        ValueListenableBuilder(
                          valueListenable: _controller,
                          builder: (context, state, _) => _RoundAction(
                            icon: state.torchState == TorchState.on
                                ? Icons.flashlight_off_outlined
                                : Icons.flashlight_on_outlined,
                            tooltip: state.torchState == TorchState.on
                                ? l10n(context).setupQrFlashOff
                                : l10n(context).setupQrFlashOn,
                            onTap:
                                state.isRunning &&
                                    !_switching &&
                                    state.torchState != TorchState.unavailable
                                ? _controller.toggleTorch
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The scanner's round dark action button, legible over the camera image.
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black54,
    shape: const CircleBorder(),
    clipBehavior: Clip.antiAlias,
    child: IconButton(
      iconSize: 26,
      padding: const EdgeInsets.all(14),
      color: Colors.white,
      disabledColor: Colors.white38,
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onTap,
    ),
  );
}
