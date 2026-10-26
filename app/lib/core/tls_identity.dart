import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../managers/settings/settings_manager.dart';
import 'command_registry.dart';
import 'events.dart';

class TlsMaterial {
  TlsMaterial(Map<Object?, Object?> data)
    : certificate = data['certificate'] as String,
      privateKey = data['privateKey'] as String,
      expires = DateTime.fromMillisecondsSinceEpoch(
        (data['notAfter'] as num).toInt(),
        isUtc: true,
      ),
      imported = data['imported'] == true,
      dnsNames = [
        for (final n in (data['dnsNames'] as List? ?? const []))
          if (n is String) n.toLowerCase(),
      ];

  final String certificate;
  final String privateKey;
  final DateTime expires;
  final bool imported;

  /// The DNS names the certificate covers, in its own order.
  final List<String> dnsNames;

  /// The name an imported certificate is reached by, for links from other
  /// kiosks: its first DNS name that is neither a wildcard nor `.local`.
  /// Null for the generated certificate, which covers only `.local`.
  String? get publicName => !imported
      ? null
      : dnsNames
            .where(
              (n) =>
                  n.contains('.') && !n.contains('*') && !n.endsWith('.local'),
            )
            .firstOrNull;

  Uint8List get der => base64Decode(
    certificate
        .split('-----BEGIN CERTIFICATE-----')[1]
        .split('-----END CERTIFICATE-----')[0]
        .replaceAll(RegExp(r'\s'), ''),
  );
  String get fingerprint => sha256.convert(der).toString();
  Map<String, Object?> get publicInfo => {
    'certificate': certificate,
    'fingerprint': fingerprint,
    'expires': expires.toIso8601String(),
    'imported': imported,
    'expired': !expires.isAfter(DateTime.now()),
  };

  SecurityContext securityContext() {
    if (!expires.isAfter(DateTime.now())) {
      throw StateError(
        'The TLS certificate has expired. Renew or import its replacement.',
      );
    }
    return SecurityContext()
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2
      ..useCertificateChainBytes(utf8.encode(certificate))
      ..usePrivateKeyBytes(utf8.encode(privateKey));
  }
}

/// Shared by the listeners. Private keys live in native encrypted storage.
class TlsIdentity {
  TlsIdentity(this.settings);
  final SettingsManager settings;
  static const channel = MethodChannel('kiosk_satellite/tls');
  TlsMaterial? _material;
  Future<void>? _operations;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = (_operations ?? Future<void>.value()).then((_) => action());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  String get hostname =>
      effectiveHostname(settings.get(deviceHostname), settings.get(deviceName));

  /// Reads a native reply, warning when the stored identity could not be
  /// opened. That happens after a restore to another device or ROM, which
  /// never brings the Keystore key along, so an imported certificate is gone
  /// and clients that trusted the old one need to trust the new one.
  TlsMaterial _read(Map<Object?, Object?> data) {
    final reason = data['unreadable'];
    if (reason is String) {
      settings.log.warn(
        'tls',
        'The stored TLS identity could not be read because $reason. It was '
            'moved to tls-identity.unreadable and a new certificate was created. '
            'If you imported a certificate, import it again. Home Assistant and '
            'other clients that trusted the old certificate need to trust the '
            'new one',
      );
    }
    return TlsMaterial(data);
  }

  Future<TlsMaterial> load() => _serial(() async {
    if (_material != null) return _material!;
    return _material = _read(
      (await channel.invokeMapMethod<Object?, Object?>('load', {
        'hostname': hostname,
      }))!,
    );
  });

  Future<TlsMaterial> change(
    String operation, [
    Map<String, Object?> params = const {},
  ]) => _serial(() async {
    final data = await channel.invokeMapMethod<Object?, Object?>(operation, {
      ...params,
      'hostname': hostname,
    });
    final material = _read(data!);
    material.securityContext();
    _material = material;
    settings.bus.publish(const TlsIdentityChanged());
    return material;
  });

  void registerCommands() {
    final commands = settings.commands;
    commands.register(
      Command(
        name: 'tlsCertificate',
        description: 'Public TLS certificate and expiration.',
        quiet: true,
        handler: (_) async => CommandResult.ok((await load()).publicInfo),
      ),
    );
    for (final entry in {
      'renewTlsCertificate': 'renew',
      'replaceTlsIdentity': 'replace',
      'importTlsCertificate': 'import',
    }.entries) {
      commands.register(
        Command(
          name: entry.key,
          description: 'Update this device TLS certificate.',
          quiet: true,
          handler: (p) async =>
              CommandResult.ok((await change(entry.value, p)).publicInfo),
        ),
      );
    }
  }
}
