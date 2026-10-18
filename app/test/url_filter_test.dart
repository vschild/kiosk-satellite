import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/browser/url_filter.dart';

UrlFilterRule wildcard(String pattern, {String scope = urlFilterAll}) =>
    UrlFilterRule(name: pattern, pattern: pattern, scope: scope);

UrlFilterRule allow(String pattern, {String scope = urlFilterAll}) =>
    UrlFilterRule(
      name: pattern,
      pattern: pattern,
      scope: scope,
      action: urlFilterAllow,
    );

UrlFilterRule regex(String pattern) =>
    UrlFilterRule(name: pattern, pattern: pattern, type: urlFilterRegex);

const ha = 'http://ha.lan:8123';

// Addresses and whether each rule should block them, shared by the Dart
// matcher and the page script so the two never disagree.
final cases = <(UrlFilterRule, String, bool)>[
  (wildcard('/history*'), '$ha/history', true),
  (wildcard('/history*'), '$ha/history?entity_id=light.den', true),
  (wildcard('/history*'), '$ha/lovelace/history', false),
  (wildcard('*/history'), '$ha/history?entity_id=light.den', true),
  (wildcard('*/history'), '$ha/history#top', true),
  (wildcard('*/history'), '$ha/history/extra', false),
  (wildcard('/config/*'), '$ha/config/areas', true),
  (wildcard('/config/*'), '$ha/configuration', false),
  (wildcard('/LOGBOOK'), '$ha/logbook', true),
  (wildcard('www.youtube.com/*'), 'https://www.youtube.com/watch?v=1', true),
  (wildcard('www.youtube.com/*'), 'https://m.youtube.com/watch', false),
  (wildcard('*youtube.com*'), 'https://m.youtube.com/watch', true),
  (wildcard('https://ha.lan:8123/profile'), '$ha/profile', false),
  (wildcard('http://ha.lan:8123/profile'), '$ha/profile', true),
  (wildcard('/history?entity_id=*'), '$ha/history', false),
  (wildcard('/history?entity_id=*'), '$ha/history?entity_id=x', true),
  (wildcard('/a.b'), '$ha/axb', false),
  (regex(r'/(history|logbook)'), '$ha/logbook?x=1', true),
  (regex(r'/(history|logbook)'), '$ha/lovelace/0', false),
  (regex(r'^https://'), '$ha/lovelace/0', false),
  (regex(r'ENERGY'), '$ha/energy', true),
];

void main() {
  test('wildcards and regular expressions match the documented way', () {
    for (final (rule, url, blocked) in cases) {
      expect(rule.matches(url), blocked, reason: '${rule.pattern} on $url');
    }
  });

  test('a rule covers only the surfaces it names', () {
    final dashboard = wildcard('/history*', scope: urlFilterDashboard);
    final external = wildcard('*youtube*', scope: urlFilterExternal);
    final rules = [dashboard, external];
    expect(
      urlFilterBlockedBy(rules, '$ha/history', {urlFilterDashboard}),
      '/history*',
    );
    expect(
      urlFilterBlockedBy(rules, '$ha/history', {urlFilterExternal}),
      isNull,
    );
    expect(
      urlFilterBlockedBy(rules, 'https://youtube.com', {urlFilterDashboard}),
      isNull,
    );
    // A dashboard link leaving for an external page answers to both.
    expect(
      urlFilterBlockedBy(rules, 'https://youtube.com', {
        urlFilterDashboard,
        urlFilterExternal,
      }),
      '*youtube*',
    );
  });

  test('an Allow only rule lets only its matches through where it applies', () {
    final exemptions = urlFilterExemptions('$ha/kiosk/0');
    String? check(List<UrlFilterRule> rules, String url, Set<String> on) =>
        urlFilterBlockedBy(rules, url, on, exemptions: exemptions);
    final lovelace = allow('/lovelace/*', scope: urlFilterDashboard);
    const dash = {urlFilterDashboard};
    expect(check([lovelace], '$ha/lovelace/1', dash), isNull);
    expect(check([lovelace], '$ha/history', dash), '');
    // Sign-in, its return and the start page always open.
    expect(check([lovelace], '$ha/auth/authorize?client_id=x', dash), isNull);
    expect(check([lovelace], '$ha/?auth_callback=1&code=x', dash), isNull);
    expect(check([lovelace], '$ha/kiosk/0', dash), isNull);
    // A Block rule wins over an Allow only rule.
    expect(
      check(
        [lovelace, wildcard('/lovelace/admin')],
        '$ha/lovelace/admin',
        dash,
      ),
      '/lovelace/admin',
    );
    // External pages are untouched by a dashboard allow list.
    expect(
      check([lovelace], 'https://example.com/', {urlFilterExternal}),
      isNull,
    );
    // A link leaving the dashboard answers to the external allow list.
    final example = allow('*example.com*', scope: urlFilterExternal);
    const leaving = {urlFilterDashboard, urlFilterExternal};
    expect(check([example], 'https://example.com/a', leaving), isNull);
    expect(check([example], 'https://youtube.com/', leaving), '');
    // The built-in allowances never turn an allow list on by themselves.
    expect(check(const [], '$ha/history', dash), isNull);
  });

  test('the stored list round-trips and skips what is malformed', () {
    final rules = [
      wildcard('/history*', scope: urlFilterDashboard),
      regex('logbook'),
      allow('/lovelace/*'),
    ];
    final parsed = parseUrlFilter(encodeUrlFilter(rules));
    expect(
      [for (final r in parsed) r.toJson()],
      [for (final r in rules) r.toJson()],
    );
    expect(
      parseUrlFilter(
        jsonEncode([
          {'name': '', 'pattern': '/x'},
          {'name': 'x', 'pattern': ' '},
          'junk',
          {
            'name': 'ok',
            'pattern': '/ok',
            'type': 'bogus',
            'scope': 'bogus',
            'action': 'bogus',
          },
        ]),
      ).map((r) => r.toJson()),
      [
        {
          'name': 'ok',
          'pattern': '/ok',
          'type': 'wildcard',
          'scope': 'all',
          'action': 'block',
        },
      ],
    );
    expect(parseUrlFilter('not json'), isEmpty);
  });

  test('a rule that cannot be used says why', () {
    expect(urlFilterRuleError(wildcard('/x')), isNull);
    expect(urlFilterRuleError(UrlFilterRule(name: ' ', pattern: '/x')), 'name');
    expect(
      urlFilterRuleError(UrlFilterRule(name: 'x', pattern: '')),
      'pattern',
    );
    expect(urlFilterRuleError(regex('(unclosed')), 'regex');
    expect(urlFilterRuleError(wildcard('(unclosed')), isNull);
  });

  test('the page script blocks exactly what the matcher blocks', () async {
    final dir = await Directory.systemTemp.createTemp('url_filter');
    addTearDown(() => dir.delete(recursive: true));
    final exemptions = urlFilterExemptions('$ha/kiosk/0');
    final lists = [
      [allow('/lovelace/*')],
      [allow('/lovelace/*'), wildcard('/lovelace/admin')],
      [regex('energy'), allow(r'/(lovelace|map)')],
    ];
    const urls = [
      '/lovelace/1',
      '/lovelace/admin',
      '/history',
      '/map',
      '/energy',
      '/auth/authorize?client_id=x',
      '/?auth_callback=1&code=x',
      '/kiosk/0',
    ];
    final checks = [
      for (final (rule, url, blocked) in cases)
        {
          'script': urlFilterJs([rule]),
          'url': url,
          'blocked': blocked,
        },
      for (final rules in lists)
        for (final path in urls)
          {
            'script': urlFilterJs(rules, exemptions: exemptions),
            'url': '$ha$path',
            'blocked':
                urlFilterBlockedBy(rules, '$ha$path', {
                  urlFilterDashboard,
                }, exemptions: exemptions) !=
                null,
          },
    ];
    final harness = File('${dir.path}/harness.mjs');
    await harness.writeAsString('''
import { runInNewContext } from 'node:vm';
const checks = ${jsonEncode(checks)};
const failures = [];
for (const c of checks) {
  const pushed = [];
  const sent = [];
  const location = { href: 'http://ha.lan:8123/lovelace/0' };
  const history = {
    pushState(state, title, url) { pushed.push(url); },
    replaceState(state, title, url) { pushed.push(url); },
  };
  const window = {
    flutter_inappwebview: { callHandler: (...args) => sent.push(args) },
  };
  runInNewContext(c.script, { window, history, location, URL });
  history.pushState(null, '', c.url);
  const blocked = pushed.length === 0;
  if (blocked !== c.blocked) failures.push(c.url + ' expected ' + c.blocked);
  if (blocked && (sent.length !== 1 || sent[0][0] !== 'ksUrlBlocked')) {
    failures.push(c.url + ' did not report');
  }
}
// The page on screen hears new rules: an empty list lets everything by.
{
  const pushed = [];
  const location = { href: 'http://ha.lan:8123/lovelace/0' };
  const history = { pushState(s, t, url) { pushed.push(url); } };
  const window = { flutter_inappwebview: { callHandler() {} } };
  const context = { window, history, location, URL };
  runInNewContext(checks[0].script, context);
  history.pushState(null, '', '/history');
  runInNewContext(${jsonEncode(urlFilterJs(const []))}, context);
  history.pushState(null, '', '/history');
  if (pushed.length !== 1) failures.push('cleared rules still block');
}
// The kiosk's own navigation goes around the check.
{
  const pushed = [];
  const location = { href: 'http://ha.lan:8123/lovelace/0' };
  const history = { pushState(s, t, url) { pushed.push(url); } };
  const window = { flutter_inappwebview: { callHandler() {} } };
  runInNewContext(checks[0].script, { window, history, location, URL });
  history.__ksPushState.call(history, null, '', '/history');
  if (pushed.length !== 1) failures.push('the kiosk push was blocked');
}
console.log(JSON.stringify(failures));
''');
    final result = await Process.run('node', [harness.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(jsonDecode((result.stdout as String).trim()), isEmpty);
  });
}
