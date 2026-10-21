import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL(
  '../lib/managers/home_assistant/home_assistant_manager.dart', import.meta.url,
), 'utf8');
const script = source.match(
  /\(function \(\) \{\n  try \{\n    var el = document\.querySelector\('home-assistant'\);\n    var hass = el && el\.hass;\n    if \(!hass \|\| !hass\.panels\) return 'null';[\s\S]*?\}\)\(\)/,
)[0];

function list(panels, { defaultPanel } = {}) {
  const hass = { panels, defaultPanel, localize: () => '' };
  const document = { querySelector: () => ({ hass }) };
  return JSON.parse(runInNewContext(script, { document }));
}

// The panels a Home Assistant 2026.10 instance reports, trimmed.
const panels = {
  config: { url_path: 'config', component_name: 'config', title: 'config', icon: 'mdi:cog' },
  lovelace: { url_path: 'lovelace', component_name: 'lovelace', title: 'Overview', icon: 'mdi:view-dashboard', config: { mode: 'storage' } },
  app: { url_path: 'app', component_name: 'app', title: null, icon: null, config: null },
  '1e25efb6_panalume': { url_path: '1e25efb6_panalume', component_name: 'app', title: 'Panalume', icon: 'mdi:greenhouse', config: { addon: '1e25efb6_panalume' } },
  'home-tablet': { url_path: 'home-tablet', component_name: 'lovelace', title: 'Home Tablet', icon: 'mdi:view-dashboard', config: { mode: 'storage' } },
  hacs: { url_path: 'hacs', component_name: 'custom', title: 'HACS', icon: 'hacs:hacs', config: { _panel_custom: { name: 'hacs-frontend' } } },
  a0d7b954_nodered: { url_path: 'a0d7b954_nodered', component_name: 'app', title: 'Node-RED', icon: 'mdi:sitemap', config: { addon: 'a0d7b954_nodered' } },
};

test('lists app panels after the dashboards', () => {
  assert.deepEqual(list(panels), [
    { url_path: 'lovelace', title: 'Overview', icon: 'mdi:view-dashboard' },
    { url_path: 'home-tablet', title: 'Home Tablet', icon: 'mdi:view-dashboard' },
    { url_path: '1e25efb6_panalume', title: 'Panalume', icon: 'mdi:greenhouse', app: true },
    { url_path: 'a0d7b954_nodered', title: 'Node-RED', icon: 'mdi:sitemap', app: true },
  ]);
});

test('skips the app store panel and other custom panels', () => {
  const paths = list(panels).map((d) => d.url_path);
  assert.ok(!paths.includes('app'));
  assert.ok(!paths.includes('hacs'));
  assert.ok(!paths.includes('config'));
});

test('names an app without a title by its path and gives it an icon', () => {
  const [app] = list({
    x_app: { url_path: 'x_app', component_name: 'app', title: null, icon: null, config: { addon: 'x_app' } },
  });
  assert.deepEqual(app, { url_path: 'x_app', title: 'x_app', icon: 'mdi:puzzle', app: true });
});

test('an app set as the default panel comes first', () => {
  assert.equal(list(panels, { defaultPanel: '1e25efb6_panalume' })[0].url_path, '1e25efb6_panalume');
});
