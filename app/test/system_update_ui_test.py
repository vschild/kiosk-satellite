"""About > System and the Overview follow the system image's updater: its repository, and a newer image that installs by hand."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from threading import Thread
from playwright.sync_api import sync_playwright, expect

APP = Path(__file__).resolve().parents[1]
ROOT = APP / 'remote-ui'
english = {k: v for p in (APP / 'l10n/source').glob('*_en.arb')
           for k, v in json.loads(p.read_text()).items() if not k.startswith('@')}
translated = {k: 'TEST ' + v for k, v in english.items()}
GUIDE = 'https://github.com/jxlarrea/lineageos-echo-kiosk-satellite/blob/main/docs/echo-dot.md#moving-from-the-cm141-image'
IMAGE = 'https://github.com/jxlarrea/lineageos-echo-kiosk-satellite'
CM14 = 'https://github.com/jxlarrea/lineageos-biscuit-kiosk-satellite'
base_status = dict(supported=True, currentVersion='2026.10.6', availableVersion=None, availableNotes=None,
                   releaseUrl='', state='idle', progress=None, lastError='', checkError='', checked=1,
                   title='LineageOS for the Echo Dot', repository=IMAGE,
                   manualVersion=None, manualNotes=None, manualUrl=None)
system = dict(base_status)
commands = []

def api(route):
    path = route.request.url.split('/api/', 1)[1]
    commands.append(path)
    if path == 'info':
        return route.fulfill(json=dict(appVersion='2026.10.40', buildNumber=340, buildMode='release',
                                       package='me.jxl.kiosk_satellite', headless=True, sdkInt=30))
    data = {'commands/getSystemUpdateStatus': system, 'commands/getUpdateStatus': {}}.get(path, {})
    route.fulfill(json=dict(ok=True, data=data))

class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(ROOT)))
Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
try:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, args=['--no-sandbox'])
        page = browser.new_page(viewport=dict(width=1100, height=1000))
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        html = (ROOT / 'index.html').read_text().replace('<script type="module" src="static/main.js?v=__KSV__"></script>', '')
        page.route(base + '/', lambda r: r.fulfill(body=html, content_type='text/html'))
        page.route('**/static/catalogs.js', lambda r: r.fulfill(body='export const catalogs = ' + json.dumps({'en': english, 'es': translated}) + ';', content_type='text/javascript'))
        page.route('**/api/**', api)
        page.context.route('https://github.com/**', lambda r: r.fulfill(body='guide', content_type='text/plain'))
        page.goto(base + '/')
        page.evaluate("""async () => {
          const core = await import('/static/core.js');
          core.showView('app');
          core.cacheSettings([{key:'ui.language',value:'es'}]);
          (await import('/static/headless.js')).applyHeadless(true);
        }""")

        def about():
            page.evaluate("""async () => {
              document.getElementById('tab-about').classList.add('active');
              await (await import('/static/device.js')).loadAboutInfo();
            }""")
            return page.locator('#about-info')

        # The LineageOS 18.1 image: its own repository, no hand install.
        root = about()
        source = root.get_by_role('link', name='jxlarrea/lineageos-echo-kiosk-satellite')
        expect(source).to_have_attribute('href', IMAGE)
        expect(root).not_to_contain_text(translated['aboutSystemManual'])

        # The CM14.1 image with a newer image to install by hand.
        system.update(repository=CM14, currentVersion='2026.10.5', manualVersion='2026.10.6',
                      manualNotes='- **LineageOS 18.1.**', manualUrl=GUIDE)
        root = about()
        expect(root.get_by_role('link', name='jxlarrea/lineageos-biscuit-kiosk-satellite')).to_have_attribute('href', CM14)
        row = root.locator('.row', has_text=translated['aboutSystemManual'])
        expect(row).to_contain_text(translated['aboutSystemManualHelp'].replace('{version}', '2026.10.6'))
        guide = row.get_by_role('link', name=translated['deviceOpenGuide'])
        expect(guide).to_have_attribute('href', GUIDE)
        expect(guide).to_have_attribute('target', '_blank')
        expect(row.locator('button')).to_have_count(0)

        # An update the updater can install wins over the hand install.
        system.update(availableVersion='2026.10.5', availableNotes='# Version 2026.10.5')
        root = about()
        expect(root).not_to_contain_text(translated['aboutSystemManual'])
        expect(root.locator('button', has_text='2026.10.5')).to_have_count(1)
        system.update(availableVersion=None, availableNotes=None)

        # The Overview's Needs attention list opens the guide.
        page.evaluate("""async () => {
          document.getElementById('tab-about').classList.remove('active');
          (await import('/static/tabs.js')).showTab('dashboard', {refresh: false});
          await (await import('/static/overview.js')).initOverview();
        }""")
        item = page.locator('#attentionCard [data-key="system-manual"]')
        expect(item).to_contain_text(translated['aboutSystemManual'])
        expect(item).to_contain_text(translated['aboutSystemManualHelp'].replace('{version}', '2026.10.6'))
        with page.expect_popup() as popup:
            item.get_by_role('button', name=translated['deviceOpenGuide']).click()
        assert popup.value.url == GUIDE, popup.value.url
        assert not any(c == 'commands/installSystemUpdate' for c in commands), commands
        assert not errors, errors
        browser.close()
finally:
    server.shutdown()
print('system update UI test passed')
