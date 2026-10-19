import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'code_scanner.dart';
import '../l10n/messages.dart';

/// Full-screen scanner for the QR code Home Assistant shows next to a newly
/// created long-lived access token, so the token never has to be typed on
/// the device. Pops with the decoded text on the first hit, or null when
/// closed. Only reachable from the setup wizard, and only on devices with a
/// camera; the remote admin's wizard keeps paste, where it belongs.
class TokenQrScanner extends StatelessWidget {
  const TokenQrScanner({super.key});

  @override
  Widget build(BuildContext context) => CodeScanner(
    title: l10n(context).setupQrTitle,
    help: l10n(context).setupQrHelp,
    formats: const [BarcodeFormat.qrCode],
    result: (outcome) => outcome.value,
  );
}
