import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/ui/plugin_settings.dart';

/// Where a plugin's readings and charts land on its page. Plugins that
/// publish readings under keys made at runtime claim them with wildcards.
void main() {
  final groups = <Map>[
    {
      'title': 'Chart demo',
      'readings': ['sensor.wave'],
      'charts': ['demo'],
    },
    {
      'title': 'Connection',
      'readings': ['binary_sensor.*'],
    },
    {
      'title': 'Home Assistant',
      'readings': ['*'],
      'charts': ['*'],
    },
  ];

  test('a named key wins over a type, and a type over the rest', () {
    expect(pluginOutputGroup(groups, 'readings', 'sensor.wave'), 'Chart demo');
    expect(
      pluginOutputGroup(groups, 'readings', 'binary_sensor.pc_1'),
      'Connection',
    );
    expect(
      pluginOutputGroup(groups, 'readings', 'sensor.r5d7e29da'),
      'Home Assistant',
    );
    expect(pluginOutputGroup(groups, 'charts', 'demo'), 'Chart demo');
    expect(pluginOutputGroup(groups, 'charts', 'load'), 'Home Assistant');
  });

  test('without a wildcard the rest stays in the plain sections', () {
    final named = groups.take(1);
    expect(pluginOutputGroup(named, 'readings', 'sensor.other'), isNull);
    expect(pluginOutputGroup(named, 'charts', 'load'), isNull);
    expect(pluginOutputGroup(const [], 'readings', 'sensor.wave'), isNull);
  });
}
