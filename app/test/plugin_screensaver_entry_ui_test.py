"""The Screensaver tab links a plugin screensaver to its plugin page, above Widgets.

Mirrors the device test (plugin_screensaver_entry_ui_test.dart). Run with
Python 3 and Playwright's Chromium installed. No device is contacted.
"""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[1] / 'remote-ui'


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(ROOT)))
Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
plugin = dict(id='hello', name='Hello World', description='A sample plugin', version='1.0.0',
              enabled=True, running=True, capabilities=['screensaver'], settings=[], commands=[], values={})
fixture = dict(mode='plugin:hello:dvd', enabled=True)


def settings():
    mode = fixture['mode']
    return [
        dict(key='screensaver.enabled', type='boolean', value=True, category='Screensaver',
             title='Enable screensaver', description=''),
        dict(key='screensaver.mode', type='select', value=mode, category='Screensaver',
             title='Screensaver mode', description='', options=['black', 'clock', mode],
             optionLabels={'black': 'Black', 'clock': 'Clock', mode: 'DVD Logo (Hello World)'}),
        dict(key='screensaver.widgets', type='string', value='[]', category='Screensaver',
             section='Widgets', subpage='Widgets', title='Widgets', description=''),
    ]


def api(route):
    name = route.request.url.rsplit('/', 1)[-1]
    data = dict(enabled=fixture['enabled'], plugins=[plugin]) if name in ('getPluginState', 'listPlugins') else []
    route.fulfill(json=dict(ok=True, data=data))


try:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, args=['--no-sandbox'])
        page = browser.new_page(viewport=dict(width=1200, height=1000))
        errors = []
        page.on('pageerror', lambda error: errors.append(str(error)))
        html = (ROOT / 'index.html').read_text().replace('<script type="module" src="static/main.js?v=__KSV__"></script>', '')
        page.route(base + '/', lambda route: route.fulfill(body=html, content_type='text/html'))
        page.route('**/api/commands/*', api)
        page.route('**/api/settings', lambda route: route.fulfill(json=dict(settings=settings(), subpageHints={})))
        page.goto(base + '/')
        load = """async () => {
          (await import('/static/core.js')).showView('app');
          await (await import('/static/settings.js')).loadSettings();
          (await import('/static/tabs.js')).showTab('screensaver', {refresh: false});
        }"""
        page.evaluate(load)
        root = page.locator('#tab-screensaver')
        entry = root.locator('[data-plugin-screensaver="hello"] .subpage-entry')
        expect(entry.locator('.name')).to_have_text('Hello World')
        expect(entry.locator('.desc')).to_have_text('A sample plugin')
        widgets = root.locator('[data-subpage-entry="Widgets"]')
        assert entry.bounding_box()['y'] < widgets.bounding_box()['y'], 'The plugin entry should sit above Widgets'
        expect(root.locator('[data-plugin-screensaver]')).to_have_count(1)
        entry.click()
        expect(page.locator('#pageTitle')).to_contain_text('Hello World')
        assert page.url.endswith('#plugins/hello'), page.url

        # A stock mode has no plugin entry.
        fixture['mode'] = 'clock'
        page.evaluate(load)
        expect(root.locator('[data-subpage-entry="Widgets"]')).to_be_visible()
        expect(root.locator('[data-plugin-screensaver]')).to_have_count(0)

        # Neither does a plugin mode while Enable Plugins is off.
        fixture['mode'] = 'plugin:hello:dvd'
        fixture['enabled'] = False
        page.evaluate(load)
        expect(root.locator('[data-subpage-entry="Widgets"]')).to_be_visible()
        page.wait_for_timeout(300)
        expect(root.locator('[data-plugin-screensaver]')).to_have_count(0)
        assert not errors, errors
        browser.close()
finally:
    server.shutdown()
print('plugin screensaver entry ok')
