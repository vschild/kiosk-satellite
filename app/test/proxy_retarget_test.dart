import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/proxy/proxy_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The secure context proxy when the start URL moves to another Home
/// Assistant origin while it runs (a kiosk moved to another VLAN, its base
/// URL changed to the address Home Assistant has there). The forwarding
/// target followed, but the reverse mapping kept the old origin, so a
/// WebView rebuild landed on the old address straight past the proxy, and
/// the log still named the old host.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProxyManager proxy;
  late SettingsManager settings;
  late HttpServer first;
  late HttpServer second;

  /// A Home Assistant stand-in that answers every request with its name.
  Future<HttpServer> upstream(String name) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.listen((req) async {
      req.response.write(name);
      await req.response.close();
    });
    return server;
  }

  String origin(String host, HttpServer s) => 'http://$host:${s.port}';

  Future<String> fetch(String path) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${proxy.port}$path'),
      );
      final res = await req.close();
      return await res.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    HttpOverrides.global = null;
    first = await upstream('first');
    second = await upstream('second');
    SharedPreferences.setMockInitialValues({
      'ks.browser.start_url': '${origin('127.0.0.2', first)}/lovelace/0',
      'ks.browser.secure_proxy': true,
    });
    final bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    proxy = ProxyManager(bus, commands, log, settings);
    await proxy.init();
    expect(proxy.running, isTrue);
  });

  tearDown(() async {
    await proxy.dispose();
    await first.close(force: true);
    await second.close(force: true);
  });

  test('a new start URL origin moves every part of the proxy', () async {
    final port = proxy.port;
    expect(await fetch('/'), 'first');

    final moved = origin('127.0.0.3', second);
    await settings.set(defs.startUrl, '$moved/lovelace/0');
    await proxy.sync();

    // Same listener, so the page keeps its origin and its login.
    expect(proxy.port, port);
    expect(proxy.targetOrigin, moved);
    expect(await fetch('/'), 'second');
    // A rebuild's unmap-then-map lands back on the proxy, not on the old
    // address directly.
    final loopback = 'http://127.0.0.1:$port/lovelace/0';
    expect(proxy.unmapUrl(loopback), '$moved/lovelace/0');
    expect(proxy.mapUrl(proxy.unmapUrl(loopback)), loopback);
    // The old origin is just another host now.
    final old = '${origin('127.0.0.2', first)}/lovelace/0';
    expect(proxy.mapUrl(old), old);
  });

  test('the same origin leaves the proxy alone', () async {
    final port = proxy.port;
    await settings.set(
      defs.startUrl,
      '${origin('127.0.0.2', first)}/dashboard-kiosk/0',
    );
    await proxy.sync();
    expect(proxy.port, port);
    expect(proxy.targetOrigin, origin('127.0.0.2', first));
    expect(await fetch('/'), 'first');
  });
}
