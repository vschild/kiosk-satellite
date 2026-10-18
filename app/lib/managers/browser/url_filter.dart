import 'dart:convert';

// URL Filter: which addresses the kiosk's web views navigate to, so a guest
// cannot leave a locked-down dashboard for Home Assistant's history, logbook
// or settings pages (issue #989), or an external page for the rest of the
// web.
//
// A rule either blocks the addresses it matches or, as an Allow only rule,
// turns the web view it covers into an allow list: once one applies there,
// only addresses an Allow only rule matches open. Block rules win over Allow
// only rules, so "/lovelace/*" can be allowed with "/lovelace/admin" still
// blocked. Home Assistant's sign-in pages and the start page always open in
// allow-list mode (see [urlFilterExemptions]), or an expired session would
// leave a dead dashboard.
//
// Only navigations made from a page are checked: a link, a script moving the
// page, Home Assistant's own routing. What the kiosk itself loads (the start
// URL, the dashboard pickers, rotation, gesture and Home Assistant actions)
// is the owner's choice and always opens.
//
// A rule is a wildcard pattern or a regular expression. Wildcards match the
// whole address, case-insensitively, with `*` standing for anything:
//
// - "/history*" starts with a slash, so it matches the path on any server.
// - "www.youtube.com/*" has no scheme, so any scheme matches.
// - "https://ha.lan:8123/config/*" matches exactly that.
//
// The query and the fragment are left out of the match unless the pattern
// has a "?" or a "#" of its own, so "*/history" also catches
// "/history?entity_id=light.den". A regular expression is searched for
// anywhere in the full address, case-insensitively.
//
// Rules compile to one form both sides read (see [UrlFilterRule.compiled]):
// Dart checks full page loads in shouldOverrideUrlLoading, and the page
// script ([urlFilterJs]) checks history.pushState and replaceState, which
// is how Home Assistant moves between its pages without loading anything.

/// Where a rule applies. [urlFilterDashboard] covers the dashboard web
/// view, custom pages included; [urlFilterExternal] covers external
/// pages, the overlay that shows dashboard links and rotation pages.
const urlFilterAll = 'all';
const urlFilterDashboard = 'dashboard';
const urlFilterExternal = 'external';
const urlFilterScopes = [urlFilterAll, urlFilterDashboard, urlFilterExternal];

/// How a rule's pattern reads.
const urlFilterWildcard = 'wildcard';
const urlFilterRegex = 'regex';
const urlFilterTypes = [urlFilterWildcard, urlFilterRegex];

/// What a rule does with the addresses it matches.
const urlFilterBlock = 'block';
const urlFilterAllow = 'allow';
const urlFilterActions = [urlFilterBlock, urlFilterAllow];

/// One rule the person added, or one of [urlFilterExemptions].
class UrlFilterRule {
  UrlFilterRule({
    required this.name,
    required this.pattern,
    this.type = urlFilterWildcard,
    this.scope = urlFilterAll,
    this.action = urlFilterBlock,
    this.exempt = false,
  });

  final String name;
  final String pattern;

  /// [urlFilterWildcard] or [urlFilterRegex].
  final String type;

  /// [urlFilterAll], [urlFilterDashboard] or [urlFilterExternal].
  final String scope;

  /// [urlFilterBlock] or [urlFilterAllow].
  final String action;

  /// A built-in allowance (see [urlFilterExemptions]): it lets an address
  /// through an allow list but never turns one on.
  final bool exempt;

  bool get isRegex => type == urlFilterRegex;
  bool get isAllow => action == urlFilterAllow;

  /// Whether the rule covers a navigation that touches any of [surfaces].
  bool appliesTo(Set<String> surfaces) =>
      scope == urlFilterAll || surfaces.contains(scope);

  /// The rule as the page script reads it: a regular expression [s], tested
  /// case-insensitively against the address with only the path when [p], and
  /// with the query and the fragment only when [q] and [f]. [a] marks an
  /// Allow only rule and [x] a built-in allowance. [n] is the name the
  /// blocked notice shows.
  late final Map<String, Object> compiled = _compile();

  late final RegExp? _regExp = () {
    try {
      return RegExp(compiled['s']! as String, caseSensitive: false);
    } catch (_) {
      return null;
    }
  }();

  Map<String, Object> _compile() {
    final flags = {'a': isAllow || exempt, 'x': exempt, 'n': name};
    if (isRegex) {
      return {'s': pattern, 'p': false, 'q': true, 'f': true, ...flags};
    }
    var p = pattern.trim();
    final pathOnly = p.startsWith('/');
    if (!pathOnly && !p.contains('://') && !p.startsWith('*')) p = '*://$p';
    final source = '^${p.split('*').map(RegExp.escape).join('.*')}\$';
    return {
      's': source,
      'p': pathOnly,
      'q': p.contains('?'),
      'f': p.contains('#'),
      ...flags,
    };
  }

  /// Whether this rule's pattern matches [url].
  bool matches(String url) {
    final re = _regExp;
    if (re == null) return false;
    return re.hasMatch(
      urlFilterSubject(
        url,
        pathOnly: compiled['p']! as bool,
        query: compiled['q']! as bool,
        fragment: compiled['f']! as bool,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'pattern': pattern,
    'type': type,
    'scope': scope,
    'action': action,
  };
}

/// The part of [url] a rule is tested against, the same cut the page script
/// makes: the fragment and the query dropped unless kept, then everything
/// before the path dropped when only the path counts.
String urlFilterSubject(
  String url, {
  required bool pathOnly,
  required bool query,
  required bool fragment,
}) {
  var s = url;
  if (!fragment) {
    final i = s.indexOf('#');
    if (i >= 0) s = s.substring(0, i);
  }
  if (!query) {
    final i = s.indexOf('?');
    if (i >= 0) {
      final hash = s.indexOf('#', i);
      s = s.substring(0, i) + (hash >= 0 ? s.substring(hash) : '');
    }
  }
  if (pathOnly) {
    final origin = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://[^/?#]*').firstMatch(s);
    if (origin != null) {
      s = s.substring(origin.end);
      if (s.isEmpty || !s.startsWith('/')) s = '/$s';
    }
  }
  return s;
}

/// The rules stored in the `browser.url_filter` setting, in their order.
/// Anything malformed is skipped rather than failing the whole list.
List<UrlFilterRule> parseUrlFilter(String raw) {
  try {
    final list = jsonDecode(raw);
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map &&
            '${e['name'] ?? ''}'.trim().isNotEmpty &&
            '${e['pattern'] ?? ''}'.trim().isNotEmpty)
          UrlFilterRule(
            name: '${e['name']}'.trim(),
            pattern: '${e['pattern']}'.trim(),
            type: urlFilterTypes.contains(e['type'])
                ? e['type'] as String
                : urlFilterWildcard,
            scope: urlFilterScopes.contains(e['scope'])
                ? e['scope'] as String
                : urlFilterAll,
            action: urlFilterActions.contains(e['action'])
                ? e['action'] as String
                : urlFilterBlock,
          ),
    ];
  } catch (_) {
    return const [];
  }
}

String encodeUrlFilter(List<UrlFilterRule> rules) =>
    jsonEncode([for (final r in rules) r.toJson()]);

/// Why a rule cannot be saved, or null when it can: 'name' or 'pattern' when
/// one is empty, 'regex' when the regular expression does not compile.
String? urlFilterRuleError(UrlFilterRule rule) {
  if (rule.name.trim().isEmpty) return 'name';
  if (rule.pattern.trim().isEmpty) return 'pattern';
  if (rule.isRegex) {
    try {
      RegExp(rule.pattern);
    } catch (_) {
      return 'regex';
    }
  }
  return null;
}

/// The addresses an allow list always lets through: Home Assistant's
/// sign-in, its return from sign-in and onboarding, and the path of the
/// kiosk's [startUrl], so a link home always works. Path patterns, so the
/// secure context proxy's loopback address matches too.
List<UrlFilterRule> urlFilterExemptions(String startUrl) {
  final start = Uri.tryParse(startUrl)?.path ?? '';
  UrlFilterRule allow(String pattern, {String type = urlFilterWildcard}) =>
      UrlFilterRule(name: '', pattern: pattern, type: type, exempt: true);
  return [
    allow('/auth/*'),
    allow('/onboarding*'),
    allow(r'[?&]auth_callback=1', type: urlFilterRegex),
    if (start.startsWith('/')) allow(start),
  ];
}

/// Whether [url] is blocked on any of [surfaces]: null when it may open,
/// the name of the Block rule that matched, or '' when an allow list covers
/// one of the surfaces and nothing on it lets [url] through.
String? urlFilterBlockedBy(
  List<UrlFilterRule> rules,
  String url,
  Set<String> surfaces, {
  List<UrlFilterRule> exemptions = const [],
}) {
  for (final rule in rules) {
    if (!rule.isAllow && rule.appliesTo(surfaces) && rule.matches(url)) {
      return rule.name;
    }
  }
  for (final surface in surfaces) {
    final allows = [
      for (final rule in rules)
        if (rule.isAllow && rule.appliesTo({surface})) rule,
    ];
    if (allows.isEmpty) continue;
    if (allows.any((r) => r.matches(url))) continue;
    if (exemptions.any((r) => r.matches(url))) continue;
    return '';
  }
  return null;
}

/// Page script that hands the page [rules] (those covering its web view)
/// with the [exemptions] and, the first time there are any rules, wraps
/// history.pushState and replaceState so a blocked address is never pushed.
/// Home Assistant reads the location after it pushes, so the page simply
/// stays where it was. The blocked address and the name of the Block rule
/// that matched ('' when it is not on the allow list) go to the
/// `ksUrlBlocked` handler for the notice.
///
/// Run at document start for every page and again on the page on screen
/// when the rules change: an empty list leaves an existing wrap passing
/// everything through. The kiosk's own navigation scripts push through
/// `history.__ksPushState`, the unwrapped original, so they are never
/// blocked.
String urlFilterJs(
  List<UrlFilterRule> rules, {
  List<UrlFilterRule> exemptions = const [],
}) {
  final compiled = jsonEncode([
    for (final r in rules) r.compiled,
    if (rules.any((r) => r.isAllow))
      for (final r in exemptions) r.compiled,
  ]);
  return '''
(function (rules) {
  var list = [];
  for (var i = 0; i < rules.length; i++) {
    try {
      var r = rules[i];
      list.push({ re: new RegExp(r.s, 'i'), p: r.p, q: r.q, f: r.f, a: r.a,
        x: r.x, n: r.n });
    } catch (e) {}
  }
  window.__ksUrlFilter = list;
  if (window.__ksUrlFilterGuard || !list.length) return;
  window.__ksUrlFilterGuard = true;
  function subject(url, r) {
    var s = url, i;
    if (!r.f) { i = s.indexOf('#'); if (i >= 0) s = s.slice(0, i); }
    if (!r.q) {
      i = s.indexOf('?');
      if (i >= 0) {
        var h = s.indexOf('#', i);
        s = s.slice(0, i) + (h >= 0 ? s.slice(h) : '');
      }
    }
    if (r.p) {
      var m = /^[a-zA-Z][a-zA-Z0-9+.\\-]*:\\/\\/[^\\/?#]*/.exec(s);
      if (m) {
        s = s.slice(m[0].length);
        if (s.charAt(0) !== '/') s = '/' + s;
      }
    }
    return s;
  }
  // The name of the Block rule that matches, '' when an allow list is on
  // and nothing on it matches, null when the address may open.
  function blocked(url) {
    var all = window.__ksUrlFilter || [];
    var listed = false, allowed = false;
    for (var i = 0; i < all.length; i++) {
      var r = all[i];
      if (r.a && !r.x) listed = true;
      if (!r.re.test(subject(url, r))) continue;
      if (!r.a) return r.n;
      allowed = true;
    }
    return listed && !allowed ? '' : null;
  }
  function wrap(name) {
    var original = history[name];
    if (typeof original !== 'function') return;
    // The kiosk's own moves (rotation, the carousel, Home Assistant
    // actions) are the owner's choice and go around the check.
    if (name === 'pushState') history.__ksPushState = original;
    history[name] = function (state, title, url) {
      if (url !== undefined && url !== null && url !== '') {
        var target = null;
        try { target = new URL(String(url), location.href).href; } catch (e) {}
        if (target && target !== location.href) {
          var rule = blocked(target);
          if (rule !== null) {
            try {
              window.flutter_inappwebview.callHandler('ksUrlBlocked', target, rule);
            } catch (e) {}
            return;
          }
        }
      }
      return original.apply(this, arguments);
    };
  }
  wrap('pushState');
  wrap('replaceState');
})($compiled);
''';
}
